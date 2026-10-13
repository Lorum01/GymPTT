import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:http/http.dart' as http;

/// Token di accesso e chiamate all'API server di LiveKit (RoomService).
class LiveKit {
  LiveKit({required this.url, required this.apiKey, required this.apiSecret})
      : _apiBase = Uri.parse(url.replaceFirst(RegExp('^ws'), 'http'));

  /// URL WebSocket per i client (wss://...).
  final String url;
  final String apiKey;
  final String apiSecret;
  final Uri _apiBase;

  String joinToken({
    required String room,
    required String identity,
    required String name,
    required String role,
  }) =>
      _sign(
        {
          'name': name,
          // Il ruolo è un attributo del partecipante: tutti nel gruppo lo
          // vedono e l'app mostra i comandi giusti. Solo il server lo cambia.
          'attributes': {'role': role},
          'video': {
            'room': room,
            'roomJoin': true,
            'canPublish': true,
            'canSubscribe': true,
            'canPublishData': true,
            'canUpdateOwnMetadata': false,
          },
        },
        subject: identity,
        ttl: const Duration(hours: 6), // una sessione di allenamento
      );

  /// Espelle un partecipante dalla stanza. Nessun errore se non è connesso.
  Future<void> removeParticipant(String room, String identity) =>
      _call('RemoveParticipant', room, {'room': room, 'identity': identity});

  /// Aggiorna il ruolo di un partecipante connesso (se non è connesso, lo
  /// riceverà nel token al prossimo ingresso).
  Future<void> updateRole(String room, String identity, String role) => _call(
        'UpdateParticipant',
        room,
        {
          'room': room,
          'identity': identity,
          'attributes': {'role': role},
        },
      );

  Future<void> _call(
      String method, String room, Map<String, Object> body) async {
    final token = _sign(
      {
        'video': {'room': room, 'roomAdmin': true},
      },
      ttl: const Duration(minutes: 5),
    );
    final res = await http.post(
      _apiBase.resolve('/twirp/livekit.RoomService/$method'),
      headers: {
        'authorization': 'Bearer $token',
        'content-type': 'application/json',
      },
      body: jsonEncode(body),
    );
    // not_found = il partecipante non è (più) nella stanza: va bene così.
    if (res.statusCode == 404 || res.body.contains('not_found')) return;
    if (res.statusCode != 200) {
      throw Exception('LiveKit $method: ${res.statusCode} ${res.body}');
    }
  }

  String _sign(Map<String, Object> claims,
      {String? subject, required Duration ttl}) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return JWT(
      {...claims, 'nbf': now - 10, 'exp': now + ttl.inSeconds},
      issuer: apiKey,
      subject: subject,
    ).sign(SecretKey(apiSecret), algorithm: JWTAlgorithm.HS256);
  }
}
