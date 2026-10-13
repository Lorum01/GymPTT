import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'identity.dart';

/// Errore restituito dal server, con un messaggio da mostrare all'utente.
class ApiException implements Exception {
  const ApiException(this.status, this.message);
  final int status;
  final String message;

  @override
  String toString() => message;
}

class RoomCredentials {
  const RoomCredentials(this.url, this.token, this.role);
  final String url;
  final String token;
  final String role;
}

class BannedUser {
  const BannedUser(this.identity, this.name);
  final String identity;
  final String name;
}

/// Client del server GymTalk (cartella `server/`).
class GymTalkApi {
  const GymTalkApi(this._me);

  final DeviceIdentity _me;

  Future<String> createGroup(String name) async {
    final body = await _post('/groups', {'name': name});
    return body['code'] as String;
  }

  Future<RoomCredentials> join(String room, String name) async {
    final body = await _post('/token', {'room': room, 'name': name});
    return RoomCredentials(
      body['url'] as String,
      body['token'] as String,
      body['role'] as String,
    );
  }

  Future<void> kick(String room, String target) =>
      _post('/groups/$room/kick', {'target': target});

  Future<void> ban(String room, String target, String targetName) =>
      _post('/groups/$room/ban', {'target': target, 'targetName': targetName});

  Future<void> unban(String room, String target) =>
      _post('/groups/$room/unban', {'target': target});

  Future<void> setAdmin(String room, String target, bool admin) =>
      _post('/groups/$room/admin', {'target': target, 'admin': admin});

  Future<List<BannedUser>> bans(String room) async {
    final body = await _post('/groups/$room/bans', {});
    return [
      for (final b in (body['bans'] as List).cast<Map<String, dynamic>>())
        BannedUser(b['identity'] as String, b['name'] as String),
    ];
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, Object?> data,
  ) async {
    final http.Response res;
    try {
      res = await http
          .post(
            Uri.parse('$tokenServerUrl$path'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({...data, 'secret': _me.secret}),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      throw const ApiException(0, 'Server GymTalk non raggiungibile');
    }
    Map<String, dynamic> body;
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      body = {};
    }
    if (res.statusCode != 200) {
      throw ApiException(
        res.statusCode,
        body['error'] as String? ?? 'Errore del server (${res.statusCode})',
      );
    }
    return body;
  }
}
