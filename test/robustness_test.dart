import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dak_push/dak_push.dart';
import 'package:dak_push/src/api.dart';
import 'package:dak_push/src/client.dart' show clampUtf8;
import 'package:dak_push/src/dak.dart' show DakOnce;
import 'package:dak_push/src/storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'fakes.dart';

/// Records the state a client saves, failing when told to.
class FlakyStorage extends MemoryDakStorage {
  bool fail = false;

  @override
  Future<void> write(String v) async {
    if (fail) throw StateError('keystore locked');
    return super.write(v);
  }
}

/// A background receipt that arrives while the app reads the kept ones.
class RacingStorage extends MemoryDakStorage {
  @override
  Future<List<String>> readReceipts() async {
    final ids = await super.readReceipts();
    await addReceipt('late');
    return ids;
  }
}

class ThrowingNative extends FakeNative {
  @override
  Future<void> shareWithExtension(String appGroup, Map<String, String> values) async =>
      throw PlatformException(code: 'app_group', message: 'App Group $appGroup is not set up');
}

void main() {
  group('D6 registration sends the whole state', () {
    test('a reinstall that gets the old token row keeps none of its user or tags', () async {
      final h = Harness();
      h.server.devices['old'] = {
        'token': 'fcm-token-1',
        'secret': 'x',
        'external_id': 'user-a',
        'tags': <String, String>{'plan': 'premium'},
      };
      await h.start();
      expect(h.client.deviceId, 'old', reason: 'the server hands over the row for this token');
      expect(h.server.devices['old']!['external_id'], isNull);
      expect(h.server.devices['old']!['tags'], isEmpty);
    });

    test('a logged-in registration sends the user with its hash', () async {
      final h = Harness();
      h.messaging.token = null;
      await h.start();
      await h.client.login('42', authHash: 'h42');
      h.messaging.tokenRefresh.add('fcm-late');
      await settle();
      final body = h.server.requests.single.body;
      expect(body['external_id'], '42');
      expect(body['auth_hash'], 'h42');
    });
  });

  group('D7 state from an earlier install', () {
    test('a first start marks the install and saves its id', () async {
      final marker = MemoryStateStore();
      final h = Harness(installMarker: marker);
      await h.start();
      expect(marker.value, hasLength(32));
      expect(jsonDecode(h.storage.value!)['install'], marker.value);
      expect(h.client.reinstalled, isFalse);
    });

    test('a restart of the same install keeps its state', () async {
      final storage = MemoryDakStorage();
      final marker = MemoryStateStore();
      final first = Harness(storage: storage, installMarker: marker);
      await first.start();
      await first.client.login('7');
      final second = Harness(storage: storage, installMarker: marker);
      second.server.devices.addAll(first.server.devices);
      await second.start();
      expect(second.client.reinstalled, isFalse);
      expect(second.client.externalId, '7');
      expect(second.server.calls, isEmpty);
    });

    test('keychain state left by an uninstalled app is dropped (iOS)', () async {
      final storage = MemoryDakStorage();
      final first = Harness(storage: storage, installMarker: MemoryStateStore());
      await first.start();
      await first.client.login('old-user');
      await first.client.setTags({'plan': 'premium'});
      await storage.addReceipt('old-receipt');

      // Reinstalled: the keychain is still there, the marker file is not.
      final marker = MemoryStateStore();
      final second = Harness(storage: storage, installMarker: marker);
      second.server.devices.addAll(first.server.devices);
      await second.start();
      expect(second.client.reinstalled, isTrue);
      expect(second.client.externalId, isNull);
      expect(second.client.tags, isEmpty);
      expect(second.server.calls, ['POST devices'], reason: 'registers again, as a new install');
      expect(second.server.requests.single.body['external_id'], isNull);
      expect(second.server.delivered, isEmpty);
      expect(storage.receipts, isEmpty);
      expect(jsonDecode(storage.value!)['install'], marker.value);
    });

    test('state from SDK 0.3 (no install id) is kept and marked', () async {
      final storage = MemoryDakStorage();
      final old = Harness(storage: storage);
      await old.start();
      await old.client.login('7');
      expect(jsonDecode(storage.value!).containsKey('install'), isFalse);

      final marker = MemoryStateStore();
      final upgraded = Harness(storage: storage, installMarker: marker);
      upgraded.server.devices.addAll(old.server.devices);
      await upgraded.start();
      expect(upgraded.client.reinstalled, isFalse);
      expect(upgraded.client.externalId, '7');
      expect(marker.value, isNotNull);
      expect(jsonDecode(storage.value!)['install'], marker.value);
    });
  });

  group('D9 lengths in UTF-8 bytes', () {
    test('tag values and user ids are limited by bytes, as the server counts', () async {
      final h = Harness();
      await h.start();
      final bangla85 = 'ক' * 85; // 255 bytes
      await h.client.setTags({'name': bangla85});
      expect(h.server.devices['dev-1']!['tags'], {'name': bangla85});
      expect(() => h.client.setTags({'name': 'ক' * 86}), throwsArgumentError);
      expect(() => h.client.login('ক' * 43), throwsArgumentError, reason: '129 bytes');
      await h.client.login('ক' * 42);
    });

    test('app and OS versions are cut to 32 bytes', () async {
      final h = Harness();
      h.platform.version = '8.0.2+533-${'x' * 40}';
      await h.start();
      expect(h.server.requests.single.body['app_version'], hasLength(32));
      expect(clampUtf8('৮.০.২', 5), '৮.', reason: 'never inside a character');
      expect(clampUtf8('short', 32), 'short');
    });
  });

  group('D10 a 401 on opens and receipts registers again', () {
    test('the open is kept and sent for the new registration', () async {
      final h = Harness();
      await h.start();
      h.server.requests.clear();
      h.server.devices.clear(); // the server deleted the device
      h.messaging.opened.add(DakNotification.fromData({'_dak_id': 'm1'}));
      await settle();
      expect(h.server.calls, ['POST devices/dev-1/opened', 'POST devices', 'POST devices/dev-3/opened']);
      expect(h.server.opened, ['m1']);
    });

    test('receipts too', () async {
      final h = Harness();
      await h.start();
      h.server.devices.clear();
      h.messaging.foreground.add(DakNotification.fromData({'_dak_id': 'm2'}));
      await settle();
      expect(h.server.delivered, ['m2']);
    });

    test('a server that keeps refusing cannot make it loop', () async {
      final h = Harness();
      await h.start();
      h.server.requests.clear();
      h.server.intercept = (method, path, body) =>
          path.endsWith('/opened') ? FakeServer.error(401, 'unauthorized') : null;
      h.messaging.opened.add(DakNotification.fromData({'_dak_id': 'm1'}));
      await settle();
      expect(h.server.calls.where((c) => c == 'POST devices'), hasLength(1));
      await h.client.flush();
      expect(h.server.calls.where((c) => c.endsWith('opened')), hasLength(2), reason: 'then dropped');
    });
  });

  group('D11 Retry-After and jitter', () {
    test('Retry-After as seconds or as a date', () {
      expect(parseRetryAfter('120'), const Duration(seconds: 120));
      final now = DateTime.utc(2026, 10, 20, 12);
      expect(parseRetryAfter('Tue, 20 Oct 2026 12:01:30 GMT', now: now), const Duration(seconds: 90));
      expect(parseRetryAfter('Tue, 20 Oct 2026 11:00:00 GMT', now: now), Duration.zero);
      expect(parseRetryAfter('soon'), isNull);
      expect(parseRetryAfter(null), isNull);
    });

    test('the server error carries it', () async {
      final server = FakeServer()
        ..intercept = (_, __, ___) => http.Response('{"error":{"code":"rate_limited","message":"slow down"}}', 429,
            headers: {'retry-after': '30'});
      final api = DakApi(baseUrl: 'https://push.test', appId: 'a', client: server.client);
      await expectLater(
        api.register({}),
        throwsA(isA<DakApiException>().having((e) => e.retryAfter, 'retryAfter', const Duration(seconds: 30))),
      );
    });

    DakClient client(Harness h, math.Random random) => DakClient(
          api: DakApi(baseUrl: 'https://push.test', appId: 'app-1', client: h.server.client),
          messaging: h.messaging,
          storage: h.storage,
          platform: h.platform,
          retryDelays: const [Duration(seconds: 10), Duration(minutes: 1)],
          random: random,
          clock: () => h.now,
        );

    test('waits a random half of each step at least, never less than Retry-After', () {
      final c = client(Harness(), math.Random(1));
      for (var i = 0; i < 50; i++) {
        final d = c.retryDelay(0);
        expect(d, greaterThanOrEqualTo(const Duration(seconds: 5)));
        expect(d, lessThanOrEqualTo(const Duration(seconds: 10)));
      }
      expect(c.retryDelay(9), lessThanOrEqualTo(const Duration(minutes: 1)), reason: 'the last step repeats');
      expect(c.retryDelay(0, retryAfter: const Duration(minutes: 3)), const Duration(minutes: 3));
      expect(c.retryDelay(0, retryAfter: const Duration(days: 2)), DakClient.maxRetryAfter);
    });

    test('during Retry-After changes are saved but not sent', () async {
      final h = Harness();
      final c = client(h, math.Random(1));
      await c.start();
      await c.firstSync;
      h.server.intercept = (_, __, ___) => http.Response('{"error":{"code":"rate_limited","message":""}}', 429,
          headers: {'retry-after': '120'});
      await c.setTags({'a': '1'});
      h.server.intercept = null;
      final before = h.server.requests.length;
      await c.setTags({'b': '2'});
      expect(h.server.requests.length, before, reason: 'the server asked for two minutes');
      expect(jsonDecode(h.storage.value!)['tags'], {'a': '1', 'b': '2'});

      h.now = h.now.add(const Duration(minutes: 3));
      await c.flush();
      expect(h.server.devices['dev-1']!['tags'], {'a': '1', 'b': '2'});
      await c.dispose();
    });
  });

  group('D12 init', () {
    test('overlapping calls share one run; a failed run can be tried again', () async {
      final once = DakOnce();
      var runs = 0;
      final gate = Completer<void>();
      final a = once(() async {
        runs++;
        await gate.future;
      });
      final b = once(() async => runs++);
      gate.complete();
      await Future.wait([a, b]);
      expect(runs, 1);
      await once(() async => runs++);
      expect(runs, 1, reason: 'done already');

      final failing = DakOnce();
      await expectLater(failing(() async => throw StateError('no Firebase')), throwsStateError);
      await failing(() async => runs++);
      expect(runs, 2);
    });
  });

  group('D13 errors stay inside the SDK', () {
    test('a failed save does not escape to the app', () async {
      final errors = <Object>[];
      await runZonedGuarded(() async {
        final storage = FlakyStorage();
        final h = Harness(storage: storage);
        await h.start();
        storage.fail = true;
        await h.client.login('1');
        h.messaging.opened.add(DakNotification.fromData({'_dak_id': 'm1'}));
        h.messaging.opened.addError(StateError('plugin'));
        await settle();
        expect(h.server.devices['dev-1']!['external_id'], '1', reason: 'still sent');
        expect(h.server.opened, ['m1']);
      }, (e, _) => errors.add(e));
      expect(errors, isEmpty);
    });

    test('no retry runs after dispose', () async {
      final h = Harness();
      final c = DakClient(
        api: DakApi(baseUrl: 'https://push.test', appId: 'app-1', client: h.server.client),
        messaging: h.messaging,
        storage: h.storage,
        platform: h.platform,
        retryDelays: const [Duration(milliseconds: 20)],
      );
      h.server.offline = true;
      await c.start();
      await c.firstSync;
      await c.dispose();
      final before = h.server.requests.length;
      h.server.offline = false;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(h.server.requests.length, before);
      await c.flush();
      expect(h.server.requests.length, before);
    });

    test('a wrong App Group is reported and the sync goes on', () async {
      final h = Harness(iosAppGroup: 'group.wrong');
      final c = DakClient(
        api: DakApi(baseUrl: 'https://push.test', appId: 'app-1', client: h.server.client),
        messaging: h.messaging,
        storage: h.storage,
        platform: h.platform,
        native: ThrowingNative(),
        iosAppGroup: 'group.wrong',
        retryDelays: const [],
        warn: h.warnings.add,
      );
      h.messaging.initial = DakNotification.fromData({'_dak_id': 'm1'});
      await c.start();
      await c.firstSync;
      expect(h.warnings.single, contains('App Group group.wrong is not set up'));
      expect(h.server.opened, ['m1']);
    });
  });

  group('D14', () {
    test('logout removes the tags too', () async {
      final h = Harness();
      await h.start();
      await h.client.login('1');
      await h.client.setTags({'plan': 'premium', 'level': 'b2'});
      await h.client.logout();
      expect(h.server.requests.last.body, {
        'external_id': null,
        'tags': {'plan': null, 'level': null},
      });
      expect(h.client.tags, isEmpty);
      expect(h.server.devices['dev-1']!['tags'], isEmpty);
    });

    test('baseUrl must be https (http only on this computer and the emulator)', () {
      expect(() => DakApi(baseUrl: 'http://push.example.com', appId: 'a'), throwsArgumentError);
      expect(() => DakApi(baseUrl: 'push.example.com', appId: 'a'), throwsArgumentError);
      expect(() => DakApi(baseUrl: 'ftp://push.example.com', appId: 'a'), throwsArgumentError);
      expect(DakApi(baseUrl: 'https://push.example.com/', appId: 'a').baseUrl, 'https://push.example.com');
      expect(DakApi(baseUrl: 'http://localhost:8080', appId: 'a').baseUrl, 'http://localhost:8080');
      expect(DakApi(baseUrl: 'http://10.0.2.2:8080', appId: 'a').baseUrl, 'http://10.0.2.2:8080');
    });

    test('a receipt kept while the app takes the others is not lost', () async {
      final storage = RacingStorage();
      await storage.addReceipt('early');
      final h = Harness(storage: storage);
      await h.start();
      expect(h.server.delivered, ['early']);
      expect(storage.receipts, ['late']);
      await h.client.onResume();
      expect(h.server.delivered, ['early', 'late']);
      expect(storage.receipts, isEmpty);
    });
  });

  group('N2 receipts the iOS extension could not send', () {
    test('are taken from the App Group on resume, and removed there once saved', () async {
      final h = Harness(iosAppGroup: 'group.app');
      await h.start();
      h.native.extensionKept['group.app'] = ['e1', 'e2'];
      await h.client.onResume();
      expect(h.server.delivered, ['e1', 'e2']);
      expect(h.native.extensionKept['group.app'], isEmpty);
    });
  });

  group('A10 showNotification', () {
    test('passes the title, body and image that FCM keeps outside the data', () {
      final n = DakNotification.fromData({'_dak_id': 'm1', 'k': 'v'},
          title: 'Hello', body: 'There', imageUrl: 'https://cdn.test/a.png');
      expect(Dak.showData(n), {
        '_dak_id': 'm1',
        'k': 'v',
        '_dak_title': 'Hello',
        '_dak_body': 'There',
        '_dak_image': 'https://cdn.test/a.png',
      });
    });
  });

  group('storage', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('dak'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('a file store writes atomically and in order', () async {
      final f = FileDakStateStore('${dir.path}/sub/in_app.json');
      expect(await f.read(), isNull);
      await Future.wait([for (var i = 0; i < 20; i++) f.write('v$i')]);
      expect(await f.read(), 'v19');
      expect(File('${dir.path}/sub/in_app.json.tmp').existsSync(), isFalse);
      await f.delete();
      expect(await f.read(), isNull);
    });

    test('the old in-app cache moves to the file once, unless it is from an earlier install', () async {
      final to = FileDakStateStore('${dir.path}/in_app.json');
      String? old = '{"sessions":3}';
      Future<void> deleteOld() async => old = null;
      await moveLegacyState(readOld: () async => old, deleteOld: deleteOld, to: to, keep: true);
      expect(await to.read(), '{"sessions":3}');
      expect(old, isNull);

      final other = FileDakStateStore('${dir.path}/other.json');
      old = '{"sessions":9}';
      await moveLegacyState(readOld: () async => old, deleteOld: deleteOld, to: other, keep: false);
      expect(await other.read(), isNull);
      expect(old, isNull);
    });

    test('secure storage keeps receipts one key each and clears only its own keys', () async {
      FlutterSecureStorage.setMockInitialValues({
        'app_token': 'the app’s own secret',
        'dak_push_receipts': '["legacy"]',
      });
      final s = SecureDakStorage();
      await s.write('{}');
      await s.addReceipt('a');
      await s.addReceipt('b');
      await s.addReceipt('a');
      expect((await s.readReceipts())..sort(), ['a', 'b', 'legacy']);
      await s.removeReceipts(['a', 'legacy']);
      expect(await s.readReceipts(), ['b']);
      await s.clear();
      final all = await const FlutterSecureStorage().readAll();
      expect(all, {'app_token': 'the app’s own secret'});
    });
  });
}
