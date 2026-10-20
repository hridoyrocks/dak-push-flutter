import 'dart:async';

import 'package:dak_push/dak_push.dart';
import 'package:flutter/material.dart';

// Pass these with --dart-define (see README.md).
const appId = String.fromEnvironment('DAK_APP_ID');
const baseUrl = String.fromEnvironment('DAK_URL');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Dak.init(
    appId: appId,
    baseUrl: baseUrl,
    options: const DakOptions(
      showInForegroundOnIOS: true,
      debugLogs: true,
      shareTimezoneOffset: true,
      // iosAppGroup: 'group.com.example.dak', // with the notification service extension
    ),
  );
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  // Dak.inAppBuilder shows in-app messages above every page.
  Widget build(BuildContext context) => const MaterialApp(builder: Dak.inAppBuilder, home: HomePage());
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _events = <String>[];
  final _user = TextEditingController();
  final _hash = TextEditingController();
  final _subs = <StreamSubscription<Object>>[];
  String _status = '';

  @override
  void initState() {
    super.initState();
    final launch = Dak.initialNotification;
    if (launch != null) _events.add('Launched from: ${launch.title} → ${launch.url} (button: ${launch.actionId})');
    _subs.add(Dak.onOpened.listen(
      (n) => setState(() => _events.add('Opened: ${n.title} → ${n.url} (button: ${n.actionId})')),
    ));
    _subs.add(Dak.onForeground.listen((n) {
      setState(() => _events.add(n.isSilent ? 'Silent: ${n.data}' : 'While open: ${n.title}: ${n.body}'));
      // Show messages with buttons the way they look in the background.
      if (n.buttons.isNotEmpty) Dak.showNotification(n);
    }));
    _subs.add(Dak.onInAppClick.listen((c) => setState(() => _events.add('In-app click: $c'))));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  Future<void> _run(String label, Future<void> Function() action) async {
    try {
      await action();
      setState(() => _status = '$label: done');
    } catch (e) {
      setState(() => _status = '$label: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dak example')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SelectableText('Device: ${Dak.deviceId ?? 'not registered yet'}'),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () => _run('Permission', () async {
              final ok = await Dak.requestPermission();
              _events.add('Permission: $ok');
            }),
            child: const Text('Ask for permission'),
          ),
          const SizedBox(height: 16),
          TextField(controller: _user, decoration: const InputDecoration(labelText: 'User id')),
          TextField(
            controller: _hash,
            decoration: const InputDecoration(labelText: 'Auth hash (dak app identity-secret → HMAC)'),
          ),
          Row(children: [
            TextButton(
              onPressed: () => _run('Login', () => Dak.login(_user.text, authHash: _hash.text)),
              child: const Text('Login'),
            ),
            TextButton(onPressed: () => _run('Logout', Dak.logout), child: const Text('Logout')),
            TextButton(
              onPressed: () => _run('Tag', () => Dak.setTags({'example': true, 'name': 'Rahim'})),
              child: const Text('Tag example, name'),
            ),
            TextButton(onPressed: () => _run('Badge', Dak.clearBadge), child: const Text('Clear badge')),
          ]),
          Row(children: [
            TextButton(
              onPressed: () => Dak.addTrigger('screen', 'example'),
              child: const Text('Trigger screen=example'),
            ),
            TextButton(onPressed: Dak.clearTriggers, child: const Text('Clear triggers')),
          ]),
          Text(_status),
          const Divider(),
          for (final e in _events.reversed) ListTile(dense: true, title: Text(e)),
        ],
      ),
    );
  }
}
