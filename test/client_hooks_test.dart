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
    await h.client.start();
    await loaded;
    expect(loadedFirst, isTrue, reason: 'loaded completes before any network call');
    await settle();
    expect(registered, hasLength(1));
    expect(h.client.credentials, (deviceId: 'dev-1', secret: h.server.devices['dev-1']!['secret']));

    await h.client.setTags({'level': 'b2'}); // an update is not a registration
    await settle();
    expect(registered, hasLength(1));
  });
}
