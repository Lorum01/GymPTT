import 'dart:convert';

import 'package:postgres/postgres.dart';

import 'groups.dart';

/// Salvataggio su Postgres (es. Neon), per i server cloud che non
/// conservano i file tra un riavvio e l'altro.
///
/// Una riga per gruppo, con il gruppo intero in JSON: semplice e sufficiente
/// per i volumi di GymTalk.
class PostgresPersistence implements GroupPersistence {
  PostgresPersistence._(this._pool);

  static Future<PostgresPersistence> connect(String databaseUrl) async {
    final pool = Pool.withUrl(_compatibleUrl(databaseUrl));
    await pool.execute('''
      CREATE TABLE IF NOT EXISTS groups (
        code TEXT PRIMARY KEY,
        data JSONB NOT NULL,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
      )
    ''');
    return PostgresPersistence._(pool);
  }

  final Pool _pool;

  @override
  Future<List<Group>> loadAll() async {
    final rows = await _pool.execute('SELECT data::text FROM groups');
    return [
      for (final row in rows)
        Group.fromJson(jsonDecode(row[0] as String) as Map<String, dynamic>),
    ];
  }

  @override
  Future<void> save(Group group) async {
    await _pool.execute(
      Sql.named('''
        INSERT INTO groups (code, data) VALUES (@code, @data::jsonb)
        ON CONFLICT (code) DO UPDATE SET data = EXCLUDED.data, updated_at = now()
      '''),
      parameters: {'code': group.code, 'data': jsonEncode(group.toJson())},
    );
  }

  /// Neon aggiunge all'URL `channel_binding=require`, che il pacchetto
  /// postgres non riconosce: lo togliamo (SSL resta obbligatorio).
  static String _compatibleUrl(String url) {
    final uri = Uri.parse(url);
    final params = Map.of(uri.queryParameters)..remove('channel_binding');
    params.putIfAbsent('sslmode', () => 'require');
    return uri.replace(queryParameters: params).toString();
  }
}
