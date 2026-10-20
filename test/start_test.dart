import 'dart:async';
import 'dart:convert';

import 'package:dak_push/dak_push.dart';
import 'package:dak_push/src/native.dart';
import 'package:dak_push/src/storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// A first run that registered, logged in and set a tag, saved in [storage].
Future<Harness> registered(LockableStorage storage) async {
  final first = Harness(storage: storage);
  await first.start();
  await first.client.login('old-user', authHash: 'h1');
  await first.client.setTags({'level': 'b2'});
  return first;
}

void main() {
  group('start does not wait for the network', () {
    test('it returns before the push token comes, and registers after', () async {
      final h = Harness();
      final token = Completer<void>();
      h.messaging.tokenDelay = token.future;
      await h.client.start();
      expect(h.server.calls, isEmpty);

      token.complete();
      await h.client.firstSync;
      expect(h.server.calls, ['POST devices']);
    });

    test('a known device starts while the server does not answer', () async {
      final storage = LockableStorage();
      final first = await registered(storage);
      final h = Harness(storage: storage);
      h.server.devices.addAll(first.server.devices);
      h.now = first.now.add(const Duration(days: 1)); // last seen is stale: a PATCH is due
      h.server.hold = Completer();
      await h.client.start();
      expect(h.client.deviceId, 'dev-1');

      h.server.hold!.complete();
      await h.client.firstSync;
      expect(h.server.calls, ['PATCH devices/dev-1']);
    });

    test('taps that come before the app listens are kept for it', () async {
      final h = Harness();
      await h.start();
      h.messaging.opened.add(DakNotification.fromData({'_dak_id': 'early'}));
      h.native.actions.add(DakNotification.fromData({'_dak_id': 'early-button'}, actionId: 'ok'));
      await settle();

      final seen = <DakNotification>[];
      h.client.onOpened.listen(seen.add);
      await settle();
      expect(seen.map((n) => n.id), ['early', 'early-button']);
      expect(h.server.opened, ['early', 'early-button']);
    });

    test('Android taps the plugin passes on before anyone listens are kept', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final native = MethodChannelDakNative();
      const codec = StandardMethodCodec();
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        'dak_push',
        codec.encodeMethodCall(const MethodCall('onAction', {
          'data': {'_dak_id': 'm1'},
          'action_id': 'accept',
        })),
        (_) {},
      );
      final got = await native.onAction.first;
      expect(got.id, 'm1');
      expect(got.actionId, 'accept');
    });
  });

  group('changes made while the saved state loads', () {
    test('wait for it and win, merged with what was saved', () async {
      final storage = LockableStorage();
      final first = await registered(storage);
      storage.gate = Completer();
      final h = Harness(storage: storage);
      h.server.devices.addAll(first.server.devices);

      final start = h.client.start();
      final login = h.client.login('new-user', authHash: 'h2');
      final tags = h.client.setTags({'vip': true});
      h.messaging.opened.add(DakNotification.fromData({'_dak_id': 'tapped-early'}));
      await settle();
      storage.gate!.complete();
      await start;
      await login;
      await tags;
      await h.client.firstSync;
      await settle();

      expect(h.client.deviceId, 'dev-1', reason: 'the saved device, not a new one');
      expect(h.client.externalId, 'new-user');
      expect(h.client.tags, {'level': 'b2', 'vip': 'true'});
      expect(h.server.devices['dev-1']!['external_id'], 'new-user');
      expect(h.server.opened, ['tapped-early']);
      expect(h.server.calls, isNot(contains('POST devices')));
    });
  });

  group('a keychain that cannot be read yet (iPhone not unlocked since it started)', () {
    test('nothing is saved or sent, and the saved device survives', () async {
      final storage = LockableStorage();
      final first = await registered(storage);
      final saved = storage.value;

      storage.locked = true;
      final h = Harness(storage: storage);
      h.server.devices.addAll(first.server.devices);
      await h.client.start(); // returns although the state cannot be read
      final login = h.client.login('42', authHash: 'h3');
      h.messaging.token = 'fcm-token-2';
      h.messaging.tokenRefresh.add('fcm-token-2');
      await settle();
      await h.client.onResume(); // still locked
      await h.client.flush();
      expect(h.server.calls, isEmpty);
      expect(storage.value, saved, reason: 'never saved over');

      storage.locked = false; // the user unlocked and opened the app
      await h.client.onResume();
      await login;
      await h.client.firstSync;
      await settle();
      expect(h.client.deviceId, 'dev-1');
      expect(h.server.calls, isNot(contains('POST devices')));
      final device = h.server.devices['dev-1']!;
      expect(device['external_id'], '42');
      expect(device['token'], 'fcm-token-2');
      expect(device['tags'], {'level': 'b2'});
      expect((jsonDecode(storage.value!) as Map)['device_id'], 'dev-1');
    });

    test('one that still fails in the foreground a minute later is given up, so the device registers', () async {
      final storage = LockableStorage(locked: true);
      final h = Harness(storage: storage);
      await h.client.start();
      await h.client.onResume();
      expect(h.server.calls, isEmpty, reason: 'one failure in the foreground may be the unlock itself');

      h.now = h.now.add(const Duration(minutes: 2));
      await h.client.onResume();
      await h.client.firstSync;
      expect(h.server.calls, contains('POST devices'));
    });

    test('retries on a timer too', () async {
      final storage = LockableStorage(locked: true);
      final h = Harness(storage: storage);
      final client = DakClient(
        api: h.client.api,
        messaging: h.messaging,
        storage: storage,
        platform: h.platform,
        retryDelays: const [Duration(milliseconds: 10)],
      );
      addTearDown(client.dispose);
      await client.start();
      storage.locked = false;
      await client.loaded.timeout(const Duration(seconds: 2));
      await client.firstSync;
      expect(h.server.calls, ['POST devices']);
    });
  });

  group('SecureDakStorage', () {
    test('iOS items are readable after the first unlock, on this device only', () {
      expect(FlutterDakKeychain.iosOptions.toMap()['accessibility'], 'first_unlock_this_device');
    });

    test('state saved by 0.3.0 with the old accessibility is moved over on first read', () async {
      final keychain = FakeKeychain()..items['dak_push_state'] = (value: '{"device_id":"dev-1"}', legacy: true);
      final storage = SecureDakStorage(keychain: keychain);
      expect(await storage.read(), '{"device_id":"dev-1"}');
      expect(keychain.items['dak_push_state'], (value: '{"device_id":"dev-1"}', legacy: false));
      await storage.write('{"device_id":"dev-1","v":2}');
      expect(await SecureDakStorage(keychain: keychain).read(), '{"device_id":"dev-1","v":2}');
    });

    test('a write before any read still replaces an old item', () async {
      final keychain = FakeKeychain()..items['dak_push_receipts'] = (value: '["a"]', legacy: true);
      await SecureDakStorage(keychain: keychain).writeReceipts('["a","b"]');
      expect(keychain.items['dak_push_receipts'], (value: '["a","b"]', legacy: false));
    });

    test('a locked keychain throws, so the client never saves over what it could not read', () async {
      final keychain = FakeKeychain()
        ..items['dak_push_state'] = (value: 'saved', legacy: false)
        ..locked = true;
      await expectLater(SecureDakStorage(keychain: keychain).read(), throwsA(isA<PlatformException>()));
      expect(keychain.items['dak_push_state']!.value, 'saved');
    });

    test('the legacy lookup runs only on iOS', () async {
      final keychain = FlutterDakKeychain();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(await keychain.readLegacy('dak_push_state'), isNull);
    });
  });
}
