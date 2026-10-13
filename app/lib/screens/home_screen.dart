import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api.dart';
import '../services/identity.dart';
import 'group_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _name = TextEditingController();
  final _code = TextEditingController();
  DeviceIdentity? _me;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final me = await DeviceIdentity.load();
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _me = me;
      _name.text = prefs.getString('name') ?? '';
      _code.text = prefs.getString('lastCode') ?? '';
    });
  }

  Future<void> _join({required bool create}) async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _toast('Inserisci il tuo nome');
      return;
    }
    String code;
    if (create) {
      setState(() => _busy = true);
      try {
        code = await GymTalkApi(_me!).createGroup(name);
      } catch (e) {
        _toast(e.toString());
        return;
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    } else {
      code = _code.text.trim().toUpperCase();
    }
    if (!RegExp(r'^[A-Z0-9]{4,12}$').hasMatch(code)) {
      _toast('Codice gruppo non valido');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('name', name);
    await prefs.setString('lastCode', code);
    _code.text = code;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GroupScreen(roomCode: code, me: _me!, name: name),
      ),
    );
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 32),
            Icon(Icons.headset_mic, size: 64, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text(
              'GymTalk',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Parla con i tuoi amici senza togliere le cuffie',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 40),
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              maxLength: 32,
              decoration: const InputDecoration(
                labelText: 'Il tuo nome',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _me == null || _busy
                  ? null
                  : () => _join(create: true),
              icon: const Icon(Icons.group_add),
              label: const Text('Crea un gruppo'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
            ),
            const SizedBox(height: 32),
            Row(
              children: [
                const Expanded(child: Divider()),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text('oppure', style: theme.textTheme.bodySmall),
                ),
                const Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _code,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Codice del gruppo',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _me == null || _busy
                  ? null
                  : () => _join(create: false),
              icon: const Icon(Icons.login),
              label: const Text('Entra nel gruppo'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
