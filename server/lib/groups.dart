import 'dart:convert';
import 'dart:io';
import 'dart:math';

enum Role { host, admin, member }

class BannedUser {
  BannedUser(this.identity, this.name, this.at);

  final String identity;
  final String name;
  final DateTime at;

  Map<String, Object> toJson() =>
      {'identity': identity, 'name': name, 'at': at.toIso8601String()};

  factory BannedUser.fromJson(Map<String, dynamic> j) => BannedUser(
      j['identity'] as String,
      j['name'] as String,
      DateTime.parse(j['at'] as String));
}

class Group {
  Group(this.code, this.hostId,
      {Set<String>? admins, Map<String, BannedUser>? bans})
      : admins = admins ?? {},
        bans = bans ?? {};

  final String code;
  final String hostId;
  final Set<String> admins;
  final Map<String, BannedUser> bans;

  Role roleOf(String identity) {
    if (identity == hostId) return Role.host;
    if (admins.contains(identity)) return Role.admin;
    return Role.member;
  }

  // Regole dei permessi:
  // - nessuno può agire sull'host;
  // - l'host può espellere/bannare chiunque e togliere admin;
  // - un admin può espellere/bannare i membri, nominare admin e sbloccare;
  // - un membro non può fare nulla.

  bool canModerate(String actor, String target) {
    if (actor == target) return false;
    final a = roleOf(actor);
    final t = roleOf(target);
    if (t == Role.host) return false;
    if (a == Role.host) return true;
    return a == Role.admin && t == Role.member;
  }

  bool canPromote(String actor, String target) =>
      actor != target &&
      roleOf(actor) != Role.member &&
      roleOf(target) == Role.member;

  bool canDemote(String actor, String target) =>
      roleOf(actor) == Role.host && roleOf(target) == Role.admin;

  bool canManageBans(String actor) => roleOf(actor) != Role.member;

  Map<String, Object> toJson() => {
        'code': code,
        'hostId': hostId,
        'admins': admins.toList(),
        'bans': bans.values.map((b) => b.toJson()).toList(),
      };

  factory Group.fromJson(Map<String, dynamic> j) => Group(
        j['code'] as String,
        j['hostId'] as String,
        admins: {...(j['admins'] as List).cast<String>()},
        bans: {
          for (final b in (j['bans'] as List).cast<Map<String, dynamic>>())
            b['identity'] as String: BannedUser.fromJson(b),
        },
      );
}

/// Dove vengono salvati i gruppi.
abstract class GroupPersistence {
  Future<List<Group>> loadAll();
  Future<void> save(Group group);
}

/// Gruppi tenuti in memoria e salvati a ogni modifica: i gruppi sono pochi,
/// quindi all'avvio si caricano tutti.
class GroupStore {
  GroupStore._(this._persistence);

  static Future<GroupStore> open(GroupPersistence persistence) async {
    final store = GroupStore._(persistence);
    for (final g in await persistence.loadAll()) {
      store._groups[g.code] = g;
    }
    return store;
  }

  final GroupPersistence _persistence;
  final _groups = <String, Group>{};

  static const _codeChars =
      'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // niente 0/O, 1/I
  final _rnd = Random.secure();

  Group? operator [](String code) => _groups[code];

  Future<Group> create(String hostId) async {
    String code;
    do {
      code =
          List.generate(6, (_) => _codeChars[_rnd.nextInt(_codeChars.length)])
              .join();
    } while (_groups.containsKey(code));
    final group = Group(code, hostId);
    _groups[code] = group;
    await save(group);
    return group;
  }

  Future<void> save(Group group) => _persistence.save(group);
}

/// Salvataggio su file JSON, per l'uso in locale sul PC.
class FilePersistence implements GroupPersistence {
  FilePersistence(this._file);

  final File _file;
  final _groups = <String, Group>{};

  @override
  Future<List<Group>> loadAll() async {
    if (!_file.existsSync()) return const [];
    final list = jsonDecode(_file.readAsStringSync()) as List;
    for (final g in list.cast<Map<String, dynamic>>()) {
      final group = Group.fromJson(g);
      _groups[group.code] = group;
    }
    return _groups.values.toList();
  }

  @override
  Future<void> save(Group group) async {
    _groups[group.code] = group;
    _file.parent.createSync(recursive: true);
    final tmp = File('${_file.path}.tmp')
      ..writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(_groups.values.toList()));
    tmp.renameSync(_file.path);
  }
}
