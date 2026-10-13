// Le API audio di LiveKit 2.13 sono marcate "experimental": la versione del
// pacchetto è fissata in pubspec.yaml, aggiornare con attenzione.
// ignore_for_file: experimental_member_use

import 'dart:io';

import 'package:livekit_client/livekit_client.dart';

/// Gestione dell'audio di sistema per il push-to-talk.
///
/// LiveKit lavora in modalità "manuale": l'audio di sistema si attiva solo
/// mentre qualcuno parla (io, oppure un amico verso di me) e in quel momento
/// abbassa la musica delle altre app (Spotify, Apple Music, ...).
///
/// - iOS: AVAudioSession `playAndRecord` + `.duckOthers`. Il motore WebRTC
///   gira solo durante il parlato; a riposo la session è disattivata e la
///   musica torna al volume pieno. `.allowBluetoothA2DP` senza
///   `.allowBluetooth` tiene le cuffie in qualità musica (A2DP) e usa il
///   microfono del telefono, evitando il profilo "telefonata" (HFP).
/// - Android: audio focus `GAIN_TRANSIENT_MAY_DUCK` in modalità normale
///   (non "in chiamata"), quindi il sistema abbassa la musica senza fermarla
///   e le cuffie Bluetooth restano su A2DP.
class VoiceAudio {
  VoiceAudio._();

  static bool _initialized = false;
  static bool _active = false;

  /// Le chiamate native vengono eseguite in ordine: premere e rilasciare
  /// velocemente non deve lasciare l'audio acceso.
  static Future<void> _queue = Future.value();

  static const _sessionOptions = AudioSessionOptions.communication(
    apple: AppleAudioSessionConfiguration(
      category: AppleAudioCategory.playAndRecord,
      categoryOptions: {
        AppleAudioCategoryOption.duckOthers,
        AppleAudioCategoryOption.allowBluetoothA2DP,
        AppleAudioCategoryOption.defaultToSpeaker,
      },
      mode: AppleAudioMode.default_,
    ),
    android: AndroidAudioSessionConfiguration(
      audioMode: AndroidAudioMode.normal,
      manageAudioFocus: true,
      focusMode: AndroidAudioFocusMode.gainTransientMayDuck,
      streamType: AndroidAudioStreamType.music,
      // Come i navigatori: la musica si abbassa invece di fermarsi.
      usageType: AndroidAudioAttributesUsageType.assistanceNavigationGuidance,
      contentType: AndroidAudioAttributesContentType.speech,
    ),
  );

  /// Da chiamare una volta all'avvio, prima di connettersi a una stanza.
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // Su Android la voce degli amici esce come audio "media", così passa
    // dalle cuffie Bluetooth in A2DP insieme alla musica.
    await LiveKitClient.initialize(
      initialAudioSessionOptions: const AudioSessionOptions.mediaPlayback(
        android: AndroidAudioSessionConfiguration(
          audioMode: AndroidAudioMode.normal,
          manageAudioFocus: false,
          streamType: AndroidAudioStreamType.music,
          usageType: AndroidAudioAttributesUsageType.media,
          contentType: AndroidAudioAttributesContentType.speech,
        ),
      ),
    );
    await AudioManager.instance.setAudioSessionManagementMode(
      AudioSessionManagementMode.manual,
    );
    if (Platform.isIOS) {
      await AudioManager.instance.setEngineAvailability(
        AudioEngineAvailability.none,
      );
    }
  }

  /// true = qualcuno sta parlando: attiva l'audio e abbassa la musica.
  static Future<void> setActive(bool active) {
    if (active == _active) return _queue;
    _active = active;
    return _queue = _queue.then((_) => _apply(active));
  }

  static Future<void> _apply(bool active) async {
    if (active) {
      await AudioManager.instance.setAudioSessionOptions(_sessionOptions);
      if (Platform.isIOS) {
        await AudioManager.instance.setEngineAvailability(
          AudioEngineAvailability.defaultAvailability,
        );
      }
    } else {
      if (Platform.isIOS) {
        await AudioManager.instance.setEngineAvailability(
          AudioEngineAvailability.none,
        );
      }
      await AudioManager.instance.deactivateAudioSession();
    }
  }
}
