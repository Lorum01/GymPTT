import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../services/api.dart';
import '../services/identity.dart';
import '../session/group_session.dart';

class GroupScreen extends StatefulWidget {
  const GroupScreen({
    super.key,
    required this.roomCode,
    required this.me,
    required this.name,
  });

  final String roomCode;
  final DeviceIdentity me;
  final String name;

  @override
  State<GroupScreen> createState() => _GroupScreenState();
}

class _GroupScreenState extends State<GroupScreen> {
  late final GroupSession _session = GroupSession(
    roomCode: widget.roomCode,
    me: widget.me,
    name: widget.name,
  );

  late final StreamSubscription<String> _messageSub;

  @override
  void initState() {
    super.initState();
    // Per l'MVP lo schermo resta acceso finché si è nel gruppo.
    WakelockPlus.enable();
    _messageSub = _session.messages.listen((msg) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(msg)));
    });
    _session.connect();
  }

  @override
  void dispose() {
    _messageSub.cancel();
    WakelockPlus.disable();
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _session,
      builder: (context, _) {
        final s = _session;
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop) return;
            if (await _confirmLeave() && context.mounted) {
              Navigator.of(context).pop();
            }
          },
          child: Scaffold(
            appBar: AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Gruppo ${widget.roomCode}'),
                  if (s.status == SessionStatus.connected &&
                      s.myRole != Role.member)
                    Text(
                      s.myRole == Role.host ? 'Sei l\'host' : 'Sei admin',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                ],
              ),
              actions: [
                if (s.canManageBans && s.status == SessionStatus.connected)
                  IconButton(
                    tooltip: 'Utenti bannati',
                    icon: const Icon(Icons.block),
                    onPressed: () => _showBans(context),
                  ),
                IconButton(
                  tooltip: 'Copia codice',
                  icon: const Icon(Icons.copy),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: widget.roomCode));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Codice copiato')),
                    );
                  },
                ),
              ],
            ),
            body: SafeArea(
              child: Column(
                children: [
                  _StatusBanner(session: s),
                  Expanded(child: _MemberList(session: s)),
                  _TalkArea(session: s),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<bool> _confirmLeave() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Uscire dal gruppo?'),
        content: const Text(
          'Gli amici non potranno più parlarti. Per restare nel gruppo usa il tasto Home.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Resta'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Esci'),
          ),
        ],
      ),
    );
    return leave ?? false;
  }

  void _showBans(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => _BansSheet(session: _session),
    );
  }
}

/// Lista degli utenti bannati, con sblocco.
class _BansSheet extends StatefulWidget {
  const _BansSheet({required this.session});
  final GroupSession session;

  @override
  State<_BansSheet> createState() => _BansSheetState();
}

class _BansSheetState extends State<_BansSheet> {
  late Future<List<BannedUser>> _bans = widget.session.loadBans();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: FutureBuilder<List<BannedUser>>(
        future: _bans,
        builder: (context, snap) {
          if (snap.hasError) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Text(snap.error.toString()),
            );
          }
          if (!snap.hasData) {
            return const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final bans = snap.data!;
          return ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Utenti bannati',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (bans.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Nessun utente bannato.'),
                ),
              for (final b in bans)
                ListTile(
                  leading: const Icon(Icons.person_off),
                  title: Text(b.name),
                  trailing: TextButton(
                    onPressed: () async {
                      await widget.session.unban(b);
                      if (!mounted) return;
                      setState(() {
                        _bans = widget.session.loadBans();
                      });
                    },
                    child: const Text('Sblocca'),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.session});
  final GroupSession session;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (String? text, Color? color) = switch (session.status) {
      SessionStatus.connecting => ('Connessione…', scheme.secondaryContainer),
      SessionStatus.reconnecting => (
        'Riconnessione…',
        scheme.tertiaryContainer,
      ),
      SessionStatus.disconnected => (
        session.error != null ? 'Disconnesso: ${session.error}' : 'Disconnesso',
        scheme.errorContainer,
      ),
      SessionStatus.connected => (null, null),
    };
    if (text == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: color,
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        children: [
          Expanded(
            child: Text(text, maxLines: 3, overflow: TextOverflow.ellipsis),
          ),
          if (session.status == SessionStatus.disconnected && !session.banned)
            TextButton(onPressed: session.retry, child: const Text('Riprova')),
        ],
      ),
    );
  }
}

class _MemberList extends StatelessWidget {
  const _MemberList({required this.session});
  final GroupSession session;

  @override
  Widget build(BuildContext context) {
    final members = session.members;
    if (members.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            session.status == SessionStatus.connected
                ? 'Nessun altro nel gruppo.\nCondividi il codice ${session.roomCode} con i tuoi amici.'
                : '',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            'Tocca un amico per parlare solo con lui',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        for (final m in members)
          _MemberTile(
            session: session,
            member: m,
            selected: session.target == m.identity,
            incoming: session.incoming[m.identity],
            onTap: () => session.selectTarget(m.identity),
            scheme: scheme,
          ),
      ],
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({
    required this.session,
    required this.member,
    required this.selected,
    required this.incoming,
    required this.onTap,
    required this.scheme,
  });

  final GroupSession session;
  final Member member;
  final bool selected;
  final IncomingTalk? incoming;
  final VoidCallback onTap;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final speaking = incoming != null;
    return ListTile(
      onTap: onTap,
      selected: selected,
      selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.35),
      leading: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: speaking ? scheme.primary : Colors.transparent,
            width: 3,
          ),
        ),
        child: CircleAvatar(
          child: Text(member.name.characters.first.toUpperCase()),
        ),
      ),
      title: Row(
        children: [
          Flexible(child: Text(member.name, overflow: TextOverflow.ellipsis)),
          if (member.role != Role.member) ...[
            const SizedBox(width: 8),
            _RoleBadge(role: member.role, scheme: scheme),
          ],
        ],
      ),
      subtitle: speaking
          ? Text(
              incoming!.private
                  ? 'Ti sta parlando (privato)'
                  : 'Sta parlando al gruppo',
              style: TextStyle(color: scheme.primary),
            )
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selected) const Icon(Icons.person_pin),
          _ModerationMenu(session: session, member: member),
        ],
      ),
    );
  }
}

class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.role, required this.scheme});
  final Role role;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final host = role == Role.host;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: host ? scheme.primary : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        host ? 'HOST' : 'ADMIN',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: host ? scheme.onPrimary : scheme.onSecondaryContainer,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

enum _Action { promote, demote, kick, ban }

/// Menu ⋮ con le azioni permesse al mio ruolo su questo membro.
class _ModerationMenu extends StatelessWidget {
  const _ModerationMenu({required this.session, required this.member});
  final GroupSession session;
  final Member member;

  @override
  Widget build(BuildContext context) {
    final id = member.identity;
    final actions = [
      if (session.canPromote(id)) _Action.promote,
      if (session.canDemote(id)) _Action.demote,
      if (session.canModerate(id)) ...[_Action.kick, _Action.ban],
    ];
    if (actions.isEmpty) return const SizedBox.shrink();

    return PopupMenuButton<_Action>(
      tooltip: 'Gestisci ${member.name}',
      onSelected: (a) => _run(context, a),
      itemBuilder: (_) => [
        for (final a in actions)
          PopupMenuItem(
            value: a,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(switch (a) {
                _Action.promote => Icons.shield,
                _Action.demote => Icons.remove_moderator,
                _Action.kick => Icons.logout,
                _Action.ban => Icons.block,
              }),
              title: Text(switch (a) {
                _Action.promote => 'Rendi admin',
                _Action.demote => 'Togli admin',
                _Action.kick => 'Espelli',
                _Action.ban => 'Banna',
              }),
            ),
          ),
      ],
    );
  }

  Future<void> _run(BuildContext context, _Action action) async {
    final id = member.identity;
    switch (action) {
      case _Action.promote:
        await session.setAdmin(id, true);
      case _Action.demote:
        await session.setAdmin(id, false);
      case _Action.kick:
        if (await _confirm(
          context,
          'Espellere ${member.name}?',
          'Uscirà dal gruppo ma potrà rientrare con il codice.',
          'Espelli',
        )) {
          await session.kick(id);
        }
      case _Action.ban:
        if (await _confirm(
          context,
          'Bannare ${member.name}?',
          'Uscirà dal gruppo e non potrà rientrare finché non verrà sbloccato.',
          'Banna',
        )) {
          await session.ban(id);
        }
    }
  }

  Future<bool> _confirm(
    BuildContext context,
    String title,
    String message,
    String confirm,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirm),
          ),
        ],
      ),
    );
    return ok ?? false;
  }
}

class _TalkArea extends StatelessWidget {
  const _TalkArea({required this.session});
  final GroupSession session;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final target = session.target;
    final targetLabel = target == null
        ? 'tutto il gruppo'
        : session.nameOf(target);
    final enabled = session.status == SessionStatus.connected;
    final talking = session.talking;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        children: [
          SegmentedButton<bool>(
            segments: [
              const ButtonSegment(
                value: true,
                icon: Icon(Icons.groups),
                label: Text('Tutti'),
              ),
              ButtonSegment(
                value: false,
                icon: const Icon(Icons.person),
                label: Text(
                  target == null ? 'Uno solo' : session.nameOf(target),
                ),
                enabled: target != null,
              ),
            ],
            selected: {target == null},
            onSelectionChanged: (sel) {
              if (sel.first) session.selectTarget(null);
            },
          ),
          const SizedBox(height: 20),
          Listener(
            onPointerDown: enabled
                ? (_) {
                    HapticFeedback.mediumImpact();
                    session.startTalking();
                  }
                : null,
            onPointerUp: (_) {
              if (session.talking) HapticFeedback.lightImpact();
              session.stopTalking();
            },
            onPointerCancel: (_) => session.stopTalking(),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: talking ? 176 : 160,
              height: talking ? 176 : 160,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: !enabled
                    ? scheme.surfaceContainerHighest
                    : talking
                    ? scheme.error
                    : scheme.primary,
                boxShadow: [
                  if (talking)
                    BoxShadow(
                      color: scheme.error.withValues(alpha: 0.5),
                      blurRadius: 32,
                      spreadRadius: 4,
                    ),
                ],
              ),
              child: Icon(
                talking ? Icons.mic : Icons.mic_none,
                size: 64,
                color: enabled ? scheme.onPrimary : scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            talking
                ? 'Stai parlando a $targetLabel'
                : 'Tieni premuto per parlare a $targetLabel',
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
