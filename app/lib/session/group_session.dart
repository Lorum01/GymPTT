import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

import '../config.dart';
import '../services/api.dart';
import '../services/identity.dart';
import '../services/voice_audio.dart';

/// Messaggi di controllo scambiati sul canale dati della stanza.
const _talkTopic = 'talk';

/// Se un "stop" va perso (rete), smettiamo comunque di abbassare la musica.
const _incomingTalkTimeout = Duration(minutes: 2);

/// Ruolo nel gruppo, deciso dal server e ricevuto come attributo LiveKit.
enum Role {
  host,
  admin,
  member;

  static Role parse(String? value) =>
      Role.values.firstWhere((r) => r.name == value, orElse: () => member);
}

class Member {
  const Member({
    required this.identity,
    required this.name,
    required this.role,
  });
  final String identity;
  final String name;
  final Role role;
}

/// Qualcuno che in questo momento sta parlando a me.
class IncomingTalk {
  const IncomingTalk({required this.private});

  /// true se parla solo a me, false se parla a tutto il gruppo.
  final bool private;
}

enum SessionStatus { connecting, connected, reconnecting, disconnected }

/// Stato di un gruppo: membri, chi parla, push-to-talk.
///
/// Instradamento audio:
/// - il microfono è pubblicato ma muto; si attiva solo tenendo premuto "Parla";
/// - per parlare a una sola persona si limitano i permessi di sottoscrizione
///   della traccia: il server LiveKit inoltra l'audio solo al destinatario;
/// - un messaggio dati "start"/"stop" (inviato solo ai destinatari) dice a chi
///   ascolta di abbassare la musica e di mostrare chi sta parlando.
class GroupSession extends ChangeNotifier {
  GroupSession({required this.roomCode, required this.me, required this.name})
    : _api = GymTalkApi(me);

  final String roomCode;
  final DeviceIdentity me;
  final String name;
  final GymTalkApi _api;

  String get identity => me.identity;

  Room? _room;
  EventsListener<RoomEvent>? _listener;

  SessionStatus status = SessionStatus.connecting;
  String? error;

  /// Bannato: inutile riprovare finché qualcuno non sblocca.
  bool banned = false;

  /// Il mio ruolo nel gruppo.
  Role get myRole => _roleOf(_room?.localParticipant) ?? _joinRole;
  Role _joinRole = Role.member;

  /// Destinatario selezionato: null = tutto il gruppo.
  String? target;

  /// Sto parlando (pulsante premuto).
  bool talking = false;

  final Map<String, IncomingTalk> incoming = {};
  final Map<String, Timer> _incomingTimers = {};

  /// Serializza press/release: un rilascio rapido non deve superare l'avvio.
  Future<void> _talkQueue = Future.value();

  List<Member> get members {
    final room = _room;
    if (room == null) return const [];
    final list =
        room.remoteParticipants.values
            .map(
              (p) => Member(
                identity: p.identity,
                name: p.name.isNotEmpty ? p.name : p.identity,
                role: _roleOf(p) ?? Role.member,
              ),
            )
            .toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
    return list;
  }

  String nameOf(String identity) {
    final p = _room?.remoteParticipants[identity];
    if (p == null) return identity;
    return p.name.isNotEmpty ? p.name : identity;
  }

  Role? _roleOf(Participant? p) =>
      p == null ? null : Role.parse(p.attributes['role']);

  Role roleOfMember(String identity) =>
      _roleOf(_room?.remoteParticipants[identity]) ?? Role.member;

  // Permessi: stesse regole del server (server/lib/groups.dart). Qui servono
  // solo a mostrare i comandi giusti: è il server a farle rispettare.

  bool canModerate(String target) {
    final t = roleOfMember(target);
    if (t == Role.host) return false;
    if (myRole == Role.host) return true;
    return myRole == Role.admin && t == Role.member;
  }

  bool canPromote(String target) =>
      myRole != Role.member && roleOfMember(target) == Role.member;

  bool canDemote(String target) =>
      myRole == Role.host && roleOfMember(target) == Role.admin;

  bool get canManageBans => myRole != Role.member;

  Future<void> kick(String target) =>
      _moderate(() => _api.kick(roomCode, target), '${nameOf(target)} espulso');

  Future<void> ban(String target) => _moderate(
    () => _api.ban(roomCode, target, nameOf(target)),
    '${nameOf(target)} bannato',
  );

  Future<void> setAdmin(String target, bool admin) => _moderate(
    () => _api.setAdmin(roomCode, target, admin),
    admin
        ? '${nameOf(target)} ora è admin'
        : '${nameOf(target)} non è più admin',
  );

  Future<void> unban(BannedUser user) => _moderate(
    () => _api.unban(roomCode, user.identity),
    '${user.name} sbloccato',
  );

  Future<List<BannedUser>> loadBans() => _api.bans(roomCode);

  Future<void> _moderate(Future<void> Function() action, String done) async {
    try {
      await action();
      _messages.add(done);
    } catch (e) {
      _messages.add(e.toString());
    }
  }

  /// Messaggi brevi per l'utente: errori di trasmissione, esito della moderazione.
  Stream<String> get messages => _messages.stream;
  final _messages = StreamController<String>.broadcast();

  /// Rientra nel gruppo dopo una disconnessione.
  Future<void> retry() async {
    await _closeRoom();
    status = SessionStatus.connecting;
    error = null;
    banned = false;
    notifyListeners();
    await connect();
  }

  Future<void> connect() async {
    try {
      await VoiceAudio.init();
      final creds = await _api.join(roomCode, name);
      _joinRole = Role.parse(creds.role);

      final room = Room(
        roomOptions: const RoomOptions(
          adaptiveStream: false,
          dynacast: false,
          defaultAudioCaptureOptions: AudioCaptureOptions(
            noiseSuppression: true, // palestra = rumore
            echoCancellation: true,
            autoGainControl: true,
          ),
          defaultAudioPublishOptions: AudioPublishOptions(dtx: true),
        ),
      );
      _room = room;
      _listener = room.createListener()
        ..on<ParticipantConnectedEvent>((_) => notifyListeners())
        ..on<ParticipantDisconnectedEvent>((e) {
          _endIncoming(e.participant.identity);
          if (target == e.participant.identity) target = null;
          notifyListeners();
        })
        ..on<ParticipantAttributesChanged>((_) => notifyListeners())
        ..on<DataReceivedEvent>(_onData)
        ..on<RoomReconnectingEvent>((_) {
          status = SessionStatus.reconnecting;
          notifyListeners();
        })
        ..on<RoomReconnectedEvent>((_) {
          status = SessionStatus.connected;
          notifyListeners();
        })
        ..on<RoomDisconnectedEvent>((e) {
          status = SessionStatus.disconnected;
          if (e.reason == DisconnectReason.participantRemoved) {
            error = 'Sei stato rimosso dal gruppo';
          }
          _clearIncoming();
          notifyListeners();
        });

      await room.connect(
        creds.url,
        creds.token,
        connectOptions: forceRelay
            ? const ConnectOptions(
                rtcConfiguration: RTCConfiguration(
                  iceTransportPolicy: RTCIceTransportPolicy.relay,
                ),
              )
            : const ConnectOptions(),
      );

      // Pubblica subito il microfono (così il permesso viene chiesto ora e
      // il primo "Parla" è immediato), poi lo mette in muto.
      final local = room.localParticipant!;
      await local.setMicrophoneEnabled(true);
      await local.setMicrophoneEnabled(false);

      status = SessionStatus.connected;
    } on ApiException catch (e) {
      error = e.message;
      banned = e.status == 403;
      status = SessionStatus.disconnected;
    } catch (e) {
      error = e.toString();
      status = SessionStatus.disconnected;
    }
    notifyListeners();
  }

  void selectTarget(String? identity) {
    if (talking) return; // non cambiare destinatario a metà frase
    target = (target == identity) ? null : identity;
    notifyListeners();
  }

  void startTalking() {
    if (talking || status != SessionStatus.connected) return;
    talking = true;
    _syncVoiceAudio();
    notifyListeners();
    _talkQueue = _talkQueue.then((_) => _doStart(target)).catchError(_onError);
  }

  void stopTalking() {
    if (!talking) return;
    talking = false;
    notifyListeners();
    _talkQueue = _talkQueue.then((_) => _doStop()).catchError(_onError);
  }

  Future<void> _doStart(String? to) async {
    final local = _room?.localParticipant;
    if (local == null) return;
    _lastTarget = to;

    // 1) chi può ricevere il mio audio
    local.setTrackSubscriptionPermissions(
      allParticipantsAllowed: to == null,
      trackPermissions: [
        if (to != null) ParticipantTrackPermission(to, true, null),
      ],
    );
    // 2) avvisa i destinatari (fa abbassare la loro musica)
    await _send({'t': 'start', 'private': to != null}, to);
    // 3) apre il microfono
    await local.setMicrophoneEnabled(true);
  }

  String? _lastTarget;

  Future<void> _doStop() async {
    final local = _room?.localParticipant;
    if (local == null) return;
    await local.setMicrophoneEnabled(false);
    await _send({'t': 'stop'}, _lastTarget);
    _syncVoiceAudio();
  }

  Future<void> _send(Map<String, Object?> msg, String? to) async {
    await _room?.localParticipant?.publishData(
      utf8.encode(jsonEncode(msg)),
      reliable: true,
      topic: _talkTopic,
      destinationIdentities: to == null ? null : [to],
    );
  }

  void _onData(DataReceivedEvent e) {
    if (e.topic != _talkTopic) return;
    final from = e.participant?.identity;
    if (from == null) return;
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(utf8.decode(e.data)) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (msg['t']) {
      case 'start':
        incoming[from] = IncomingTalk(private: msg['private'] == true);
        _incomingTimers[from]?.cancel();
        _incomingTimers[from] = Timer(
          _incomingTalkTimeout,
          () => _endIncoming(from),
        );
      case 'stop':
        _endIncoming(from);
    }
    _syncVoiceAudio();
    notifyListeners();
  }

  void _endIncoming(String from) {
    _incomingTimers.remove(from)?.cancel();
    if (incoming.remove(from) != null) {
      _syncVoiceAudio();
      notifyListeners();
    }
  }

  void _clearIncoming() {
    for (final t in _incomingTimers.values) {
      t.cancel();
    }
    _incomingTimers.clear();
    incoming.clear();
    _syncVoiceAudio();
  }

  /// Musica abbassata finché parlo io o qualcuno parla a me.
  void _syncVoiceAudio() {
    VoiceAudio.setActive(talking || incoming.isNotEmpty).catchError(_onError);
  }

  void _onError(Object e) {
    debugPrint('GymTalk: $e');
    if (!_disposed) {
      _messages.add(
        e is TimeoutException || e.toString().contains('Timeout')
            ? 'Connessione lenta: messaggio non inviato, riprova'
            : 'Errore audio: $e',
      );
    }
  }

  Future<void> _closeRoom() async {
    talking = false;
    _clearIncoming();
    await _listener?.dispose();
    _listener = null;
    await _room?.disconnect();
    await _room?.dispose();
    _room = null;
  }

  Future<void> leave() async {
    await _closeRoom();
    await VoiceAudio.setActive(false);
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    leave().whenComplete(_messages.close);
    super.dispose();
  }
}
