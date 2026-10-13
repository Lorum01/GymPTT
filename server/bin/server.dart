// Server GymTalk: gruppi, ruoli, ban e token di accesso LiveKit.
//
// Ogni richiesta dell'app contiene il `secret` del telefono: da questo il
// server ricava l'identità (vedi lib/identity.dart) e applica i permessi.
// La API secret di LiveKit resta qui e non finisce mai nell'app.
//
// Endpoint (JSON in POST, il segreto non va mai nell'URL):
//   POST /groups                  {secret, name}           → {code}
//   POST /token                   {secret, name, room}     → {url, token, role}
//   POST /groups/<code>/kick      {secret, target}
//   POST /groups/<code>/ban       {secret, target, targetName}
//   POST /groups/<code>/unban     {secret, target}
//   POST /groups/<code>/admin     {secret, target, admin: bool}
//   POST /groups/<code>/bans      {secret}                 → {bans: [...]}
//
// Configurazione: variabili d'ambiente oppure file `.env` nella cartella
// server/ (le variabili d'ambiente hanno la precedenza). Chiavi richieste:
//   LIVEKIT_URL         es. wss://mio-progetto.livekit.cloud
//   LIVEKIT_API_KEY
//   LIVEKIT_API_SECRET
//   PORT                (opzionale, default 8080)

import 'dart:convert';
import 'dart:io';

import 'package:gymtalk_token_server/groups.dart';
import 'package:gymtalk_token_server/identity.dart';
import 'package:gymtalk_token_server/livekit.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';

Future<void> main() async {
  final env = {..._readDotEnv(), ...Platform.environment};
  final livekit = LiveKit(
    url: _require(env, 'LIVEKIT_URL'),
    apiKey: _require(env, 'LIVEKIT_API_KEY'),
    apiSecret: _require(env, 'LIVEKIT_API_SECRET'),
  );
  final port = int.tryParse(env['PORT'] ?? '') ?? 8080;
  final store =
      GroupStore(File.fromUri(Platform.script.resolve('../data/groups.json')));

  final router = Router()
    ..get('/', (Request _) => Response.ok('GymTalk server attivo'))
    ..get('/health', (Request _) => Response.ok('ok'))
    ..post('/groups', (Request req) async {
      final body = await _body(req);
      final me = _caller(body);
      if (me == null || _name(body) == null)
        return _error(400, 'Richiesta non valida');
      final group = store.create(me);
      return _json(200, {'code': group.code});
    })
    ..post('/token', (Request req) async {
      final body = await _body(req);
      final me = _caller(body);
      final name = _name(body);
      final code = (body['room'] as String? ?? '').toUpperCase();
      if (me == null || name == null)
        return _error(400, 'Richiesta non valida');
      final group = store[code];
      if (group == null) return _error(404, 'Gruppo $code inesistente');
      if (group.bans.containsKey(me)) {
        return _error(403, 'Sei stato bannato da questo gruppo');
      }
      final role = group.roleOf(me).name;
      return _json(200, {
        'url': livekit.url,
        'role': role,
        'token':
            livekit.joinToken(room: code, identity: me, name: name, role: role),
      });
    })
    ..post('/groups/<code>/kick', (Request req, String code) async {
      return _moderate(req, store, code, (group, me, target, body) async {
        if (!group.canModerate(me, target)) return _forbidden();
        await livekit.removeParticipant(code, target);
        return _json(200, {'ok': true});
      });
    })
    ..post('/groups/<code>/ban', (Request req, String code) async {
      return _moderate(req, store, code, (group, me, target, body) async {
        if (!group.canModerate(me, target)) return _forbidden();
        final targetName = (body['targetName'] as String? ?? '').trim();
        group.admins.remove(target);
        group.bans[target] = BannedUser(
          target,
          targetName.isEmpty ? target : targetName,
          DateTime.now().toUtc(),
        );
        store.save();
        await livekit.removeParticipant(code, target);
        return _json(200, {'ok': true});
      });
    })
    ..post('/groups/<code>/unban', (Request req, String code) async {
      return _moderate(req, store, code, (group, me, target, body) async {
        if (!group.canManageBans(me)) return _forbidden();
        group.bans.remove(target);
        store.save();
        return _json(200, {'ok': true});
      });
    })
    ..post('/groups/<code>/admin', (Request req, String code) async {
      return _moderate(req, store, code, (group, me, target, body) async {
        final makeAdmin = body['admin'] == true;
        if (makeAdmin) {
          if (!group.canPromote(me, target)) return _forbidden();
          group.admins.add(target);
        } else {
          if (!group.canDemote(me, target)) return _forbidden();
          group.admins.remove(target);
        }
        store.save();
        await livekit.updateRole(code, target, group.roleOf(target).name);
        return _json(200, {'ok': true});
      });
    })
    ..post('/groups/<code>/bans', (Request req, String code) async {
      final body = await _body(req);
      final me = _caller(body);
      final group = store[code.toUpperCase()];
      if (me == null) return _error(400, 'Richiesta non valida');
      if (group == null) return _error(404, 'Gruppo inesistente');
      if (!group.canManageBans(me)) return _forbidden();
      return _json(200, {
        'bans': group.bans.values.map((b) => b.toJson()).toList(),
      });
    });

  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(_catchErrors)
      .addHandler(router.call);
  final server = await io.serve(handler, InternetAddress.anyIPv4, port);
  stdout.writeln('GymTalk server su http://${server.address.host}:$port');
}

typedef _Action = Future<Response> Function(
    Group group, String me, String target, Map<String, dynamic> body);

/// Parte comune delle azioni di moderazione: autentica chi chiede e trova il gruppo.
Future<Response> _moderate(
    Request req, GroupStore store, String code, _Action action) async {
  final body = await _body(req);
  final me = _caller(body);
  final target = body['target'];
  if (me == null || target is! String || target.isEmpty) {
    return _error(400, 'Richiesta non valida');
  }
  final group = store[code.toUpperCase()];
  if (group == null) return _error(404, 'Gruppo inesistente');
  return action(group, me, target, body);
}

Future<Map<String, dynamic>> _body(Request req) async {
  try {
    final decoded = jsonDecode(await req.readAsString());
    return decoded is Map<String, dynamic> ? decoded : {};
  } catch (_) {
    return {};
  }
}

/// Identità di chi fa la richiesta, ricavata dal suo segreto.
String? _caller(Map<String, dynamic> body) {
  final secret = body['secret'];
  return secret is String && isValidSecret(secret)
      ? identityFromSecret(secret)
      : null;
}

String? _name(Map<String, dynamic> body) {
  final name = (body['name'] as String? ?? '').trim();
  return name.isEmpty || name.length > 32 ? null : name;
}

Handler _catchErrors(Handler inner) => (req) async {
      try {
        return await inner(req);
      } catch (e, st) {
        stderr.writeln('Errore: $e\n$st');
        return _error(500, 'Errore del server');
      }
    };

Response _forbidden() => _error(403, 'Non hai i permessi per questa azione');

Response _error(int status, String message) =>
    _json(status, {'error': message});

Response _json(int status, Object body) => Response(
      status,
      body: jsonEncode(body),
      headers: {'content-type': 'application/json'},
    );

/// Legge `KEY=valore` da server/.env (righe vuote e `#` ignorate).
Map<String, String> _readDotEnv() {
  final file = File.fromUri(Platform.script.resolve('../.env'));
  if (!file.existsSync()) return {};
  final result = <String, String>{};
  for (final line in file.readAsLinesSync()) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final i = trimmed.indexOf('=');
    if (i <= 0) continue;
    result[trimmed.substring(0, i).trim()] = trimmed.substring(i + 1).trim();
  }
  return result;
}

String _require(Map<String, String> env, String name) {
  final value = env[name];
  if (value == null || value.isEmpty) {
    stderr.writeln(
        'Configurazione mancante: $name (in server/.env o come variabile d\'ambiente)');
    exit(64);
  }
  return value;
}
