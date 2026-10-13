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

/// Gruppi salvati su file JSON: sopravvivono al riavvio del server.
class GroupStore {
  GroupStore(this._file) {
    if (_file.existsSync()) {
      final list = jsonDecode(_file.readAsStringSync()) as List;
      for (final g in list.cast<Map<String, dynamic>>()) {
        final group = Group.fromJson(g);
        _groups[group.code] = group;
      }
    }
  }

  final File _file;
  final _groups = <String, Group>{};

  static const _codeChars =
      'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // niente 0/O, 1/I
  final _rnd = Random.secure();

  Group? operator [](String code) => _groups[code];

  Group create(String hostId) {
    String code;
    do {
      code =
          List.generate(6, (_) => _codeChars[_rnd.nextInt(_codeChars.length)])
              .join();
    } while (_groups.containsKey(code));
    final group = Group(code, hostId);
    _groups[code] = group;
    save();
    return group;
  }

  void save() {
    _file.parent.createSync(recursive: true);
    final tmp = File('${_file.path}.tmp')
      ..writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(_groups.values.toList()));
    tmp.renameSync(_file.path);
  }
}
