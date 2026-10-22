import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  test('in-app hooks: loaded, credentials and a signal on registration', () async {
    final h = Harness();
    final registered = <void>[];
    h.client.onRegistered.listen(registered.add);
    expect(h.client.credentials, isNull);

    var loadedFirst = false;
    final loaded = h.client.loaded.then((_) => loadedFirst = h.server.requests.isEmpty);
    await h.start();
    await loaded;
    expect(loadedFirst, isTrue, reason: 'loaded completes before any network call');
    await settle();
    expect(registered, hasLength(1));
    expect(h.client.credentials, (deviceId: 'dev-1', secret: h.server.devices['dev-1']!['secret']));

    await h.client.setTags({'level': 'b2'}); // an update is not a registration
    await settle();
    expect(registered, hasLength(1));
  });

  group('onDeviceId', () {
    test('the id once registered, at once for a later listener, a new one after registering again', () async {
      final h = Harness();
      final ids = <String>[];
      h.client.onDeviceId.listen(ids.add);
      await h.start();
      await settle();
      expect(ids, ['dev-1']);

      final late = <String>[];
      h.client.onDeviceId.listen(late.add);
      await settle();
      expect(late, ['dev-1'], reason: 'a listener that comes later gets the current id');

      await h.client.setTags({'level': 'b2'}); // an update keeps the id
      await settle();
      expect(ids, ['dev-1']);

      h.server.devices.clear(); // the server forgot the device
      await h.client.setSubscribed(false);
      await settle();
      final again = h.client.deviceId!;
      expect(again, isNot('dev-1'));
      expect(ids, ['dev-1', again]);
      expect(late, ['dev-1', again]);
    });

    test('the saved id, without a registration', () async {
      final first = Harness();
      await first.start();
      final h = Harness(storage: first.storage);
      h.server.devices.addAll(first.server.devices);

      final ids = <String>[];
      h.client.onDeviceId.listen(ids.add);
      await h.start();
      await settle();
      expect(ids, ['dev-1']);
      expect(h.server.calls, isNot(contains('POST devices')));
    });

    test('nothing before the device registers; done after dispose', () async {
      final h = Harness();
      h.messaging.token = null; // no push token, so nothing to register
      final ids = <String>[];
      var done = false;
      h.client.onDeviceId.listen(ids.add, onDone: () => done = true);
      await h.start();
      await settle();
      expect(ids, isEmpty);

      await h.client.dispose();
      await settle();
      expect(done, isTrue);
    });
  });
}
