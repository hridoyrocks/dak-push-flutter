import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dak_push/dak_push.dart';
import 'package:dak_push/src/background.dart';
import 'package:dak_push/src/client.dart' show kDakSdkVersion;
import 'package:dak_push/src/messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

/// Looks like FirebaseMessaging 17: register() and onRegistered.
class Messaging17 {
  final registered = StreamController<String>.broadcast();
  int registers = 0;
  bool answer = true;

  Stream<String> get onRegistered => registered.stream;

  Future<void> register() async {
    registers++;
    if (answer) scheduleMicrotask(() => registered.add('fid-abc'));
  }
}

/// Looks like FirebaseMessaging 15/16: no register().
class Messaging15 {
  Future<String?> getToken() async => 'token-15';
}

class Message17 {
  Message17(this.actionIdentifier);
  final String? actionIdentifier;
}

class Message15 {}

void main() {
  group('Firebase Installation IDs', () {
    test('register() gives the FID on firebase_messaging 17', () async {
      final fm = Messaging17();
      expect(await registerFid(fm), 'fid-abc');
      expect(fm.registers, 1);
      expect(fidUpdates(fm), isNotNull);
    });

    test('15 and 16 have no register(): fall back to tokens', () async {
      expect(await registerFid(Messaging15()), isNull);
      expect(fidUpdates(Messaging15()), isNull);
    });

    test('a registration that never answers times out', () async {
      final fm = Messaging17()..answer = false;
      expect(await registerFid(fm, timeout: const Duration(milliseconds: 50)), isNull);
    });

    test('the action identifier is read only where it exists', () {
      expect(actionIdentifierOf(Message17('accept')), 'accept');
      expect(actionIdentifierOf(Message17('com.apple.UNNotificationDefaultActionIdentifier')), isNull);
      expect(actionIdentifierOf(Message17(null)), isNull);
      expect(actionIdentifierOf(Message15()), isNull);
    });

    test('a FID is registered with its type, and a switch sends both', () async {
      final h = Harness();
      h.messaging.tokenType = 'fid';
      h.messaging.token = 'fid-1';
      await h.client.start();
      expect(h.server.requests.single.body['token_type'], 'fid');

      h.messaging.tokenType = 'token';
      h.messaging.tokenRefresh.add('token-2');
      await settle();
      expect(h.server.requests.last.body, {'token': 'token-2', 'token_type': 'token'});
    });
  });

  group('delivered receipts', () {
    test('foreground messages are reported, once, in batches', () async {
      final h = Harness();
      await h.client.start();
      h.messaging.foreground.add(DakNotification.fromData({'_dak_id': 'm1'}));
      h.messaging.foreground.add(DakNotification.fromData({'_dak_id': 'm1'}));
      h.messaging.foreground.add(DakNotification.fromData({'not_dak': '1'}));
      await settle();
      expect(h.server.delivered, ['m1']);
    });

    test('receipts made offline are sent later', () async {
      final h = Harness();
      await h.client.start();
      h.server.offline = true;
      h.messaging.foreground.add(DakNotification.fromData({'_dak_id': 'm1'}));
      await settle();
      h.server.offline = false;
      await h.client.flush();
      expect(h.server.delivered, ['m1']);
    });

    test('the background handler reports with the saved device secret', () async {
      final h = Harness();
      await h.client.start();
      final sent = <http.Request>[];
      final client = MockClient((req) async {
        sent.add(req);
        return http.Response('', 204);
      });
      await reportDelivery({'_dak_id': 'm9', 'type': 'x'}, storage: h.storage, client: client);
      expect(sent.single.url.toString(), 'https://push.test/v1/apps/app-1/devices/dev-1/delivered');
      expect(sent.single.headers['Authorization'], startsWith('Device secret-'));
      expect(jsonDecode(sent.single.body), {'message_ids': ['m9']});
      expect(h.storage.receipts, isEmpty);

      // Pushes from other services are ignored.
      await reportDelivery({'type': 'x'}, storage: h.storage, client: client);
      expect(sent, hasLength(1));
    });

    test('without network the background handler keeps receipts for the app', () async {
      final h = Harness();
      await h.client.start();
      final offline = MockClient((_) async => throw http.ClientException('no network'));
      await reportDelivery({'_dak_id': 'b1'}, storage: h.storage, client: offline);
      await reportDelivery({'_dak_id': 'b2'}, storage: h.storage, client: offline);
      await reportDelivery({'_dak_id': 'b1'}, storage: h.storage, client: offline);
      expect(h.storage.receipts, ['b1', 'b2']);

      await h.client.onResume();
      expect(h.server.delivered, ['b1', 'b2']);
      expect(h.storage.receipts, isEmpty);
    });

    test('before the first registration the receipt waits too', () async {
      final storage = MemoryDakStorage();
      await reportDelivery({'_dak_id': 'early'}, storage: storage, client: MockClient((_) async => http.Response('', 204)));
      expect(storage.receipts, ['early']);
      final h = Harness(storage: storage);
      await h.client.start();
      expect(h.server.delivered, ['early']);
    });

    test('a refused receipt is not kept', () async {
      final h = Harness();
      await h.client.start();
      final refuse = MockClient((_) async => http.Response('{"error":{"code":"invalid","message":"x"}}', 422));
      await reportDelivery({'_dak_id': 'x1'}, storage: h.storage, client: refuse);
      expect(h.storage.receipts, isEmpty);
    });
  });

  group('buttons', () {
    const buttons = '[{"id":"accept","text":"Accept","url":"app://accept"},{"id":"later","text":"Later"}]';

    test('notifications read SDK-shown fields, buttons and the tapped button URL', () {
      final n = DakNotification.fromData({
        '_dak_id': 'm1',
        '_dak_url': 'app://message',
        '_dak_title': 'Friend request',
        '_dak_body': 'Rahim',
        '_dak_image': 'https://cdn.example.com/r.png',
        '_dak_buttons': buttons,
        'kind': 'friend',
      });
      expect(n.title, 'Friend request');
      expect(n.body, 'Rahim');
      expect(n.imageUrl, 'https://cdn.example.com/r.png');
      expect(n.buttons.map((b) => b.id), ['accept', 'later']);
      expect(n.data, {'kind': 'friend'});
      expect(n.url, 'app://message');
      expect(n.withAction('accept').url, 'app://accept');
      expect(n.withAction('later').url, 'app://message');
      expect(n.withAction('later').actionId, 'later');
      expect(DakNotification.fromData({'_dak_buttons': 'not json'}).buttons, isEmpty);
      expect(DakNotification.fromData({'sync': '1'}).isSilent, isTrue);
    });

    test('Android: taps on SDK-shown notifications report the button', () async {
      final h = Harness();
      h.native.initial = DakNotification.fromData({'_dak_id': 'm0', '_dak_buttons': buttons}, actionId: 'accept');
      await h.client.start();
      await settle();
      expect(h.client.initialNotification!.url, 'app://accept');

      final seen = <DakNotification>[];
      h.client.onOpened.listen(seen.add);
      h.native.actions.add(DakNotification.fromData({'_dak_id': 'm1', '_dak_buttons': buttons}, actionId: 'later'));
      h.native.actions.add(DakNotification.fromData({'_dak_id': 'm2', '_dak_buttons': buttons}));
      await settle();
      expect(h.server.opened, ['m0', 'm1', 'm2']);
      expect(h.server.openedActions, ['accept', 'later', null]);
      expect(seen.map((n) => n.actionId), ['later', null]);
    });

    test('iOS with firebase_messaging 15/16: the plugin knows the button', () async {
      final h = Harness();
      await h.client.start();
      h.native.iosActions['m1'] = 'accept';
      final seen = <DakNotification>[];
      h.client.onOpened.listen(seen.add);
      h.messaging.opened.add(DakNotification.fromData({'_dak_id': 'm1', '_dak_buttons': buttons}));
      await settle();
      expect(seen.single.actionId, 'accept');
      expect(seen.single.url, 'app://accept');
      expect(h.server.openedActions, ['accept']);
    });
  });

  group('UTC offset', () {
    test('is sent only when the app opts in, and again when it changes', () async {
      final off = Harness();
      await off.client.start();
      // Sent as null, so a row this install takes over loses an old offset.
      expect(off.server.requests.single.body['utc_offset_minutes'], isNull);
      expect(off.server.requests.single.body.containsKey('utc_offset_minutes'), isTrue);

      final h = Harness(shareTimezoneOffset: true);
      await h.client.start();
      expect(h.server.requests.single.body['utc_offset_minutes'], 360);
      h.platform.offset = 330; // travelled to India
      await h.client.onResume();
      expect(h.server.requests.last.body, {'utc_offset_minutes': 330});
    });

    test('turning it off clears it on the server', () async {
      final storage = MemoryDakStorage();
      final first = Harness(storage: storage, shareTimezoneOffset: true);
      await first.client.start();
      final second = Harness(storage: storage);
      second.server.devices.addAll(first.server.devices);
      await second.client.start();
      expect(second.server.requests.single.body, {'utc_offset_minutes': null});
    });
  });

  group('iOS extension and badge', () {
    test('the extension gets the receipt token, never the secret', () async {
      final h = Harness(iosAppGroup: 'group.app');
      await h.client.start();
      final shared = h.native.shared.single;
      final secret = h.server.devices['dev-1']!['secret'] as String;
      expect(shared.group, 'group.app');
      expect(shared.values, {
        'base_url': 'https://push.test',
        'app_id': 'app-1',
        'device_id': 'dev-1',
        'receipt_token': sha256.convert(utf8.encode(secret)).toString(),
      });
      expect(shared.values.values, isNot(contains(secret)));
      await h.client.setTags({'a': 'b'});
      expect(h.native.shared, hasLength(1), reason: 'shared once per device secret');
      expect(receiptToken(secret), shared.values['receipt_token']);
    });

    test('without an App Group nothing is shared', () async {
      final h = Harness();
      await h.client.start();
      expect(h.native.shared, isEmpty);
    });

    test('setBadge goes to the plugin with the App Group', () async {
      final h = Harness(iosAppGroup: 'group.app');
      await h.client.start();
      await h.client.setBadge(-3);
      expect(h.native.badge, 0);
      await h.client.setBadge(4);
      expect(h.native.badge, 4);
      expect(h.native.badgeGroup, 'group.app');
    });
  });

  test('state saved by SDK 0.1 still loads', () async {
    final storage = MemoryDakStorage()
      ..value = jsonEncode({
        'v': 1,
        'device_id': 'dev-1',
        'secret': 'secret-2',
        'token': 'fcm-token-1',
        'tags': {'level': 'b2'},
        'subscribed': true,
        'reported': {'token': 'fcm-token-1', 'platform': 'android', 'tags': {'level': 'b2'}},
        'last_seen_sent': DateTime(2026, 10, 20, 11).toIso8601String(),
        'opens': ['old-open'],
      });
    final h = Harness(storage: storage);
    h.server.devices['dev-1'] = {'secret': 'secret-2', 'tags': <String, String>{}, 'token': 'fcm-token-1'};
    await h.client.start();
    expect(h.server.opened, ['old-open']);
    final patch = h.server.requests.first.body;
    expect(patch.containsKey('token'), isFalse, reason: 'an unchanged token keeps its (default) type');
    expect(patch['sdk_version'], kDakSdkVersion);
    final saved = jsonDecode(storage.value!) as Map<String, dynamic>;
    expect(saved['v'], 2);
    expect(saved['base_url'], 'https://push.test');
  });
}
