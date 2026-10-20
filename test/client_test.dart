import 'package:dak_push/dak_push.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  test('start registers the device with what the server needs, and nothing more', () async {
    final h = Harness();
    await h.start();

    expect(h.server.calls, ['POST devices']);
    final body = h.server.requests.single.body;
    expect(body, {
      'token': 'fcm-token-1',
      'token_type': 'token',
      'platform': 'android',
      'app_version': '8.0.2+533',
      'os_version': '14',
      'sdk_version': '0.3.1',
      'language': 'bn',
      'push_permission': false,
      'subscribed': true,
      'tags': <String, dynamic>{},
    });
    expect(h.client.deviceId, 'dev-1');
  });

  test('a restart does not register again, and only refreshes last seen when stale', () async {
    final storage = MemoryDakStorage();
    final first = Harness(storage: storage);
    await first.start();

    final second = Harness(storage: storage);
    second.server.devices.addAll(first.server.devices);
    second.now = first.now.add(const Duration(hours: 1));
    await second.start();
    expect(second.server.calls, isEmpty, reason: 'nothing changed, last seen is fresh');

    final third = Harness(storage: storage);
    third.server.devices.addAll(first.server.devices);
    third.now = first.now.add(const Duration(hours: 13));
    third.platform.version = '8.0.3+540';
    await third.start();
    expect(third.server.calls, ['PATCH devices/dev-1']);
    expect(third.server.requests.single.body, {'app_version': '8.0.3+540'});
  });

  test('login sends the user id with its hash; logout clears it', () async {
    final h = Harness();
    await h.start();
    await h.client.login('123', authHash: 'abc');
    expect(h.server.requests.last.body, {'external_id': '123', 'auth_hash': 'abc'});
    expect(h.server.devices['dev-1']!['external_id'], '123');

    await h.client.logout();
    expect(h.server.requests.last.body, {'external_id': null});
    expect(h.server.devices['dev-1']!['external_id'], isNull);

    expect(() => h.client.login('me@example.com'), throwsArgumentError);
  });

  test('tags: only the changes are sent, null and empty remove', () async {
    final h = Harness();
    await h.start();
    await h.client.setTags({'level': 'b2', 'score': 5, 'vip': true});
    expect(h.server.requests.last.body, {
      'tags': {'level': 'b2', 'score': '5', 'vip': 'true'}
    });
    await h.client.setTags({'level': 'c1', 'vip': null});
    expect(h.server.requests.last.body, {
      'tags': {'level': 'c1', 'vip': null}
    });
    await h.client.deleteTags(['score']);
    expect(h.server.devices['dev-1']!['tags'], {'level': 'c1'});
    expect(h.client.tags, {'level': 'c1'});

    expect(() => h.client.setTags({'bad key': 'x'}), throwsArgumentError);
    expect(() => h.client.setTags({'k': <int>[]}), throwsArgumentError);
    expect(() => h.client.setTags({for (var i = 0; i < 60; i++) 'k$i': 'v'}), throwsArgumentError);
  });

  test('changes made offline are kept and sent later', () async {
    final h = Harness();
    h.server.offline = true;
    await h.start(); // fails quietly
    await h.client.login('123', authHash: 'abc'); // network errors do not throw
    await h.client.setTags({'level': 'b2'});
    expect(h.client.deviceId, isNull);

    h.server.offline = false;
    await h.client.flush();
    expect(h.server.calls, ['POST devices']);
    final body = h.server.requests.single.body;
    expect(body['external_id'], '123');
    expect(body['auth_hash'], 'abc');
    expect(body['tags'], {'level': 'b2'});
  });

  test('state survives an app restart while offline', () async {
    final storage = MemoryDakStorage();
    final first = Harness(storage: storage);
    first.server.offline = true;
    await first.start();
    await first.client.setTags({'level': 'b2'});

    final second = Harness(storage: storage);
    await second.start();
    expect(second.server.requests.single.body['tags'], {'level': 'b2'});
  });

  test('a token refresh is sent', () async {
    final h = Harness();
    await h.start();
    h.messaging.tokenRefresh.add('fcm-token-2');
    await settle();
    expect(h.server.requests.last.body, {'token': 'fcm-token-2', 'token_type': 'token'});
    expect(h.server.devices['dev-1']!['token'], 'fcm-token-2');
  });

  test('when the server forgot the device, it registers again with everything', () async {
    final h = Harness();
    await h.start();
    await h.client.login('123', authHash: 'abc');
    await h.client.setTags({'level': 'b2'});

    h.server.devices.clear(); // e.g. deleted after 270 days
    await h.client.setSubscribed(false);

    expect(h.server.calls.skip(3).toList(), ['PATCH devices/dev-1', 'POST devices']);
    final body = h.server.requests.last.body;
    expect(body['external_id'], '123');
    expect(body['auth_hash'], 'abc');
    expect(body['tags'], {'level': 'b2'});
    expect(body['subscribed'], false);
    expect(h.client.deviceId, isNot('dev-1'));
  });

  test('a refused auth hash throws and is rolled back, other changes still go', () async {
    final h = Harness();
    await h.start();
    await h.client.setTags({'level': 'b2'});
    h.server.intercept = (method, path, body) =>
        body['auth_hash'] == 'wrong' ? FakeServer.error(403, 'identity_verification_failed') : null;

    await expectLater(h.client.login('123', authHash: 'wrong'), throwsA(isA<DakException>()));
    expect(h.client.externalId, isNull);

    await h.client.setTags({'level': 'c1'});
    expect(h.server.devices['dev-1']!['tags'], {'level': 'c1'});
  });

  test('permission prompt result is reported', () async {
    final h = Harness();
    await h.start();
    expect(await h.client.requestPermission(), isTrue);
    expect(h.server.requests.last.body, {'push_permission': true});

    h.messaging.permission = false; // user turned it off in system settings
    await h.client.onResume();
    expect(h.server.requests.last.body, {'push_permission': false});
  });

  test('opens are reported once, for launch and background taps', () async {
    final h = Harness();
    h.messaging.initial = DakNotification.fromData({'_dak_id': 'msg-1', '_dak_url': 'app://a', 'type': 'x'});
    await h.start();
    await settle();
    expect(h.client.initialNotification!.url, 'app://a');
    expect(h.client.initialNotification!.data, {'type': 'x'});

    final seen = <DakNotification>[];
    h.client.onOpened.listen(seen.add);
    h.messaging.opened.add(DakNotification.fromData({'_dak_id': 'msg-2'}));
    h.messaging.opened.add(DakNotification.fromData({'_dak_id': 'msg-2'}));
    h.messaging.opened.add(DakNotification.fromData({'from_another_service': '1'})); // no Dak id
    await settle();

    expect(h.server.opened, ['msg-1', 'msg-2']);
    expect(seen, hasLength(3));
  });

  test('opens wait for the device to be registered', () async {
    final h = Harness();
    h.server.offline = true;
    h.messaging.initial = DakNotification.fromData({'_dak_id': 'msg-1'});
    await h.start();
    h.server.offline = false;
    await h.client.flush();
    expect(h.server.calls, ['POST devices', 'POST devices/dev-1/opened']);
  });

  test('foreground messages are passed through', () async {
    final h = Harness();
    await h.start();
    final got = <DakNotification>[];
    h.client.onForeground.listen(got.add);
    h.messaging.foreground.add(DakNotification.fromData(
      {'_dak_id': 'm1', 'type': 'new_follower'},
      title: 'Hi',
      body: 'there',
      imageUrl: 'https://cdn.example.com/a.png',
    ));
    await settle();
    expect(got.single.title, 'Hi');
    expect(got.single.imageUrl, 'https://cdn.example.com/a.png');
    expect(got.single.data, {'type': 'new_follower'});
  });

  test('without a token nothing is registered until one arrives', () async {
    final h = Harness();
    h.messaging.token = null;
    await h.start();
    expect(h.server.calls, isEmpty);
    h.messaging.tokenRefresh.add('late-token');
    await settle();
    expect(h.server.calls, ['POST devices']);
    expect(h.server.requests.single.body['token'], 'late-token');
  });
}
