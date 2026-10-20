import 'dart:async';

import 'package:dak_push/dak_push.dart';
import 'package:dak_push/src/api.dart';
import 'package:dak_push/src/client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

Future<DakApiException> refusal(DakApi api) async {
  try {
    await api.update('d', 's', {});
  } on DakApiException catch (e) {
    return e;
  }
  throw StateError('the request was not refused');
}

void main() {
  group('refused changes', () {
    test('a wrong auth hash rolls back the user only; the opt-out still goes', () async {
      final h = Harness();
      await h.start();
      final errors = <DakException>[];
      h.client.onError.listen(errors.add);

      h.server.offline = true;
      await h.client.setSubscribed(false);
      await h.client.login('42', authHash: 'wrong');
      h.server.offline = false;
      h.server.intercept = (method, path, body) =>
          body['auth_hash'] == 'wrong' ? FakeServer.error(403, 'identity_verification_failed') : null;

      await h.client.flush();
      expect(h.server.devices['dev-1']!['subscribed'], false);
      expect(h.client.externalId, isNull);
      expect(errors.single.code, 'identity_verification_failed');

      // Still opted out after a restart.
      final again = Harness(storage: h.storage);
      again.server.devices.addAll(h.server.devices);
      await again.start();
      expect(again.server.calls, isEmpty);
    });

    test('a refused tag rolls back the tags only; the user still goes', () async {
      final h = Harness();
      await h.start();
      h.server.offline = true;
      await h.client.login('42', authHash: 'abc');
      await h.client.setTags({'level': 'b2'});
      h.server.offline = false;
      h.server.intercept = (method, path, body) => body.containsKey('tags')
          ? FakeServer.jsonError(422, {'code': 'invalid', 'field': 'tags', 'message': 'tag "level" is not allowed'})
          : null;

      await h.client.flush();
      expect(h.server.devices['dev-1']!['external_id'], '42');
      expect(h.client.externalId, '42');
      expect(h.client.tags, isEmpty);
    });

    test('a refusal of a field the app cannot roll back is thrown and kept as it is', () async {
      final h = Harness();
      await h.start();
      h.server.intercept = (method, path, body) => body.containsKey('subscribed')
          ? FakeServer.jsonError(422, {'code': 'invalid', 'field': 'subscribed', 'message': 'no'})
          : null;
      final errors = <DakException>[];
      h.client.onError.listen(errors.add);

      await expectLater(h.client.setSubscribed(false), throwsA(isA<DakException>()));
      await settle();
      expect(errors.single.field, 'subscribed');
      h.server.intercept = null;
      await h.client.flush();
      expect(h.server.devices['dev-1']!['subscribed'], false, reason: 'the opt-out is never rolled back');
    });

    test('a 4xx that is not from Dak (a proxy page) is retried, not acted on', () async {
      final h = Harness();
      await h.start();
      h.server.intercept =
          (method, path, body) => http.Response('<html>403 Forbidden</html>', 403, headers: {'content-type': 'text/html'});
      await h.client.login('42', authHash: 'abc'); // a network problem: no throw
      expect(h.client.externalId, '42');

      h.server.intercept =
          (method, path, body) => http.Response('<html>401</html>', 401, headers: {'content-type': 'text/html'});
      await h.client.setTags({'level': 'b2'});
      expect(h.client.deviceId, 'dev-1', reason: 'a proxy 401 does not drop the device');

      h.server.intercept = null;
      await h.client.flush();
      expect(h.server.devices['dev-1']!['external_id'], '42');
      expect(h.server.devices['dev-1']!['tags'], {'level': 'b2'});
      expect(h.server.calls.where((c) => c == 'POST devices'), hasLength(1), reason: 'only the first registration');
    });

    test('the error says what Dak sent', () async {
      final api = DakApi(
        baseUrl: 'https://push.test',
        appId: 'a',
        client: MockClient((_) async => FakeServer.jsonError(422, {'code': 'invalid', 'field': 'tags', 'message': 'bad'})),
      );
      final e = await refusal(api);
      expect((e.status, e.code, e.field, e.message, e.fromDak, e.isPermanent), (422, 'invalid', 'tags', 'bad', true, true));

      final proxy = DakApi(
        baseUrl: 'https://push.test',
        appId: 'a',
        client: MockClient((_) async => http.Response('{"message":"not dak"}', 404)),
      );
      final p = await refusal(proxy);
      expect((p.code, p.fromDak, p.isPermanent, p.isUnauthorized), ('http_404', false, false, false));
    });
  });

  group('timeouts', () {
    test('a server that sends headers and then stalls times out', () async {
      var cancelled = false;
      final body = StreamController<List<int>>(onCancel: () => cancelled = true);
      final api = DakApi(
        baseUrl: 'https://push.test',
        appId: 'a',
        timeout: const Duration(milliseconds: 50),
        client: MockClient.streaming((req, _) async => http.StreamedResponse(body.stream, 200)),
      );
      await expectLater(api.update('d', 's', {'tags': {}}), throwsA(isA<TimeoutException>()));
      await settle();
      expect(cancelled, isTrue, reason: 'the stalled answer is closed');
    });

    test('a stalled sync does not hold the next one', () async {
      final h = Harness();
      await h.start();
      final stalled = StreamController<List<int>>();
      var stall = true;
      final client = DakClient(
        api: DakApi(
          baseUrl: 'https://push.test',
          appId: 'app-1',
          timeout: const Duration(milliseconds: 50),
          client: MockClient.streaming((req, body) async {
            if (stall) return http.StreamedResponse(stalled.stream, 200);
            return h.server.client.send(http.Request(req.method, req.url)
              ..headers.addAll(req.headers)
              ..bodyBytes = await body.toBytes());
          }),
        ),
        messaging: h.messaging,
        storage: h.storage,
        platform: h.platform,
        retryDelays: const [],
        clock: () => h.now,
      );
      addTearDown(client.dispose);
      await client.start();
      await client.firstSync;
      await client.setTags({'a': '1'}).timeout(const Duration(seconds: 2));
      stall = false;
      await client.setTags({'b': '2'}).timeout(const Duration(seconds: 2));
      expect(h.server.devices['dev-1']!['tags'], {'a': '1', 'b': '2'});
    });
  });
}
