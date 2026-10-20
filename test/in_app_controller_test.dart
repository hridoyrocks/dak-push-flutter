import 'package:dak_push/dak_push.dart' show MemoryDakStorage;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'fakes.dart';

void main() {
  late InAppHarness h;
  setUp(() => h = InAppHarness());
  tearDown(() => h.controller.dispose());

  /// Leaves the app for [away] and comes back.
  void background(Duration away) {
    h.controller.lifecycle(AppLifecycleState.paused);
    h.now = h.now.add(away);
    h.controller.lifecycle(AppLifecycleState.resumed);
  }

  test('a session start fetches the list and shows the highest priority message', () async {
    h.server.inApp = [inAppMessage('low', priority: 1), inAppMessage('high', priority: 5), inAppMessage('also-low', priority: 1)];
    final c = await h.start();
    expect(h.server.calls, ['GET devices/dev-1/in-app']);
    expect(c.messages.map((m) => m.id), ['high', 'low', 'also-low'], reason: 'ties keep the server order');
    expect(c.sessionCount, 1);
    expect(h.showing, 'high');

    h.display();
    await c.flushEvents();
    expect(h.eventTypes, ['impression high']);
    final e = h.server.inAppEvents.single;
    expect(e['seq'], greaterThan(0));
    expect(DateTime.parse(e['at'] as String), h.now.toUtc());
  });

  test('nothing shows before the host is attached, and while paused', () async {
    h.server.inApp = [inAppMessage('a')];
    final c = await h.start(attach: false);
    expect(h.showing, isNull);
    c.setPaused(true);
    c.attach();
    expect(h.showing, isNull);
    expect(c.isPaused, isTrue);
    c.setPaused(false);
    expect(h.showing, 'a');
  });

  test('one message at a time; one triggered meanwhile follows, a refreshed list does not', () async {
    h.server.inApp = [
      inAppMessage('first'),
      inAppMessage('on-home', triggers: [
        [
          {'kind': 'custom', 'key': 'screen', 'op': '=', 'value': 'home'}
        ]
      ]),
      inAppMessage('plain'),
    ];
    final c = await h.start();
    h.display();
    c.addTriggers({'screen': 'home'});
    expect(h.showing, 'first', reason: 'still the first one');

    c.dismiss(c.current.value!);
    expect(h.showing, 'on-home', reason: 'the triggered one follows');
    h.display();
    c.dismiss(c.current.value!);
    expect(h.showing, isNull, reason: 'no event since: "plain" waits for the next one');

    await c.refresh(force: true);
    c.check();
    expect(h.showing, 'plain');
  });

  group('triggers', () {
    Future<bool> shows(List<List<Map<String, Object?>>> triggers, {Map<String, Object> set = const {}, int sessions = 1}) async {
      final local = InAppHarness();
      addTearDown(local.controller.dispose);
      local.server.inApp = [inAppMessage('m', triggers: triggers, frequency: {'type': 'every_session'})];
      final c = await local.start(attach: false);
      for (var i = 1; i < sessions; i++) {
        c.lifecycle(AppLifecycleState.paused);
        local.now = local.now.add(const Duration(hours: 1));
        c.lifecycle(AppLifecycleState.resumed);
        await Future<void>.delayed(Duration.zero);
      }
      if (set.isNotEmpty) c.addTriggers(set);
      c.attach();
      return local.showing == 'm';
    }

    Map<String, Object?> custom(String op, [Object? value]) => {
          'kind': 'custom',
          'key': 'k',
          'op': op,
          if (op == 'in') 'values': value else if (value != null) 'value': value,
        };

    test('custom', () async {
      expect(await shows([[custom('=', 'home')]], set: {'k': 'home'}), isTrue);
      expect(await shows([[custom('=', 'home')]], set: {'k': 'away'}), isFalse);
      expect(await shows([[custom('=', 'home')]]), isFalse);
      expect(await shows([[custom('=', 5)]], set: {'k': '5'}), isTrue, reason: 'numbers compare as numbers');
      expect(await shows([[custom('=', 5)]], set: {'k': 5.0}), isTrue);
      expect(await shows([[custom('=', true)]], set: {'k': true}), isTrue);
      expect(await shows([[custom('!=', 'home')]]), isTrue, reason: 'an unset trigger is not "home"');
      expect(await shows([[custom('!=', 'home')]], set: {'k': 'home'}), isFalse);
      expect(await shows([[custom('>', 3)]], set: {'k': 4}), isTrue);
      expect(await shows([[custom('>', 3)]], set: {'k': '10'}), isTrue);
      expect(await shows([[custom('<=', 3)]], set: {'k': 4}), isFalse);
      expect(await shows([[custom('>', 3)]], set: {'k': 'x'}), isFalse);
      expect(await shows([[custom('in', ['b1', 'b2'])]], set: {'k': 'b2'}), isTrue);
      expect(await shows([[custom('in', ['1', '2'])]], set: {'k': 2.0}), isTrue);
      expect(await shows([[custom('in', ['b1'])]], set: {'k': 'c1'}), isFalse);
      expect(await shows([[custom('exists')]], set: {'k': false}), isTrue);
      expect(await shows([[custom('exists')]]), isFalse);
      expect(await shows([[custom('not_exists')]]), isTrue);
    });

    test('groups: OR between groups, AND inside', () async {
      final a = {'kind': 'custom', 'key': 'a', 'op': 'exists'};
      final b = {'kind': 'custom', 'key': 'b', 'op': 'exists'};
      final c = {'kind': 'custom', 'key': 'c', 'op': 'exists'};
      expect(await shows([[a, b]], set: {'a': 1}), isFalse);
      expect(await shows([[a, b]], set: {'a': 1, 'b': 1}), isTrue);
      expect(await shows([[a, b], [c]], set: {'c': 1}), isTrue);
    });

    test('session count', () async {
      final third = [
        [
          {'kind': 'session_count', 'op': '>=', 'value': 3}
        ]
      ];
      expect(await shows(third, sessions: 2), isFalse);
      expect(await shows(third, sessions: 3), isTrue);
      expect(await shows([
        [
          {'kind': 'session_count', 'op': '=', 'value': 1}
        ]
      ]), isTrue);
    });

    test('triggers are checked when they change, and validated', () async {
      h.server.inApp = [inAppMessage('m', triggers: [[custom('not_exists')]])];
      final c = await h.start(attach: false);
      c.addTriggers({'k': 1});
      c.attach();
      expect(h.showing, isNull);
      c.removeTriggers(['k']);
      expect(h.showing, 'm');
      expect(c.triggers, isEmpty);
      expect(() => c.addTriggers({'bad key': 1}), throwsArgumentError);
      expect(() => c.addTriggers({'k': <int>[]}), throwsArgumentError);
    });
  });

  test('time triggers wake the controller up when they come true', () async {
    h.server.inApp = [
      inAppMessage('after-30s', triggers: [
        [
          {'kind': 'session_time', 'op': '>=', 'value': 30}
        ]
      ]),
      inAppMessage('after-a-day', triggers: [
        [
          {'kind': 'since_install', 'op': '>=', 'value': 86400}
        ]
      ]),
    ];
    final start = h.now;
    final c = await h.start();
    expect(h.showing, isNull);
    expect(c.nextTimeCheck, start.add(const Duration(seconds: 30)));

    h.now = start.add(const Duration(seconds: 30));
    c.check(); // what the timer does
    expect(h.showing, 'after-30s');
    h.display();
    c.dismiss(c.current.value!);
    expect(c.nextTimeCheck, start.add(const Duration(days: 1)));

    // The install time is kept across restarts.
    final again = InAppHarness(storage: h.storage)..now = start.add(const Duration(days: 1, minutes: 1));
    addTearDown(again.controller.dispose);
    again.server.inApp = h.server.inApp;
    await again.start();
    expect(again.showing, 'after-a-day');
    expect(again.controller.sessionCount, 2);
  });

  test('once: never again, also after a restart before the server knows', () async {
    h.server.inApp = [inAppMessage('m')];
    final c = await h.start();
    h.display();
    c.dismiss(c.current.value!);
    background(const Duration(hours: 2));
    await Future<void>.delayed(Duration.zero);
    expect(c.sessionCount, 2);
    expect(h.showing, isNull);

    final restarted = InAppHarness(storage: h.storage)..now = h.now.add(const Duration(days: 1));
    addTearDown(restarted.controller.dispose);
    restarted.server.inApp = [inAppMessage('m')]; // shown: 0, events not counted yet
    await restarted.start();
    expect(restarted.showing, isNull);
  });

  test('every session, at most max_displays; a short trip away is the same session', () async {
    h.server.inApp = [
      inAppMessage('m', frequency: {'type': 'every_session', 'max_displays': 2})
    ];
    final c = await h.start();
    expect(h.display(), 'm');
    c.dismiss(c.current.value!);

    background(const Duration(minutes: 1));
    await Future<void>.delayed(Duration.zero);
    expect(c.sessionCount, 1);
    c.check();
    expect(h.showing, isNull);

    background(const Duration(minutes: 6));
    await Future<void>.delayed(Duration.zero);
    expect(c.sessionCount, 2);
    expect(h.display(), 'm');
    c.dismiss(c.current.value!);

    background(const Duration(minutes: 6));
    await Future<void>.delayed(Duration.zero);
    expect(c.sessionCount, 3);
    expect(h.showing, isNull, reason: 'shown twice already');
  });

  test('interval', () async {
    h.server.inApp = [
      inAppMessage('m', frequency: {'type': 'interval', 'interval_seconds': 7200})
    ];
    final c = await h.start();
    expect(h.display(), 'm');
    c.dismiss(c.current.value!);
    h.now = h.now.add(const Duration(hours: 1));
    c.check();
    expect(h.showing, isNull);
    h.now = h.now.add(const Duration(hours: 1));
    c.check();
    expect(h.showing, 'm');
  });

  test("the server's counts are merged with the phone's", () async {
    h.server.inApp = [
      inAppMessage('seen-once', shown: 1),
      inAppMessage('recent', frequency: {'type': 'interval', 'interval_seconds': 3600}, shown: 1, lastShownAt: h.now.subtract(const Duration(minutes: 10)).toUtc().toIso8601String()),
      inAppMessage('maxed', frequency: {'type': 'every_session', 'max_displays': 3}, shown: 3),
      inAppMessage('ok', frequency: {'type': 'interval', 'interval_seconds': 3600}, shown: 4, lastShownAt: h.now.subtract(const Duration(hours: 2)).toUtc().toIso8601String()),
    ];
    await h.start();
    expect(h.showing, 'ok');
  });

  test('schedule window', () async {
    final soon = h.now.add(const Duration(hours: 1));
    h.server.inApp = [
      inAppMessage('ended', endAt: h.now.subtract(const Duration(minutes: 1)).toUtc().toIso8601String()),
      inAppMessage('later', startAt: soon.toUtc().toIso8601String(), endAt: soon.add(const Duration(hours: 1)).toUtc().toIso8601String()),
    ];
    final c = await h.start();
    expect(h.showing, isNull);
    h.now = soon;
    c.check();
    expect(h.showing, 'later');
    h.controller.setPaused(true);
    h.now = soon.add(const Duration(hours: 1));
    h.controller.setPaused(false);
    expect(h.showing, isNull, reason: 'over at end_at');
  });

  test('pausing hides the message on screen without counting a dismissal; blocks nest', () async {
    h.server.inApp = [inAppMessage('a', priority: 2), inAppMessage('b', priority: 1)];
    final c = await h.start();
    h.display();
    c.block();
    c.block();
    expect(h.showing, isNull);
    c.unblock();
    expect(c.isPaused, isTrue);
    expect(h.showing, isNull);
    c.unblock();
    expect(c.isPaused, isFalse);
    expect(h.showing, 'b', reason: '"a" was seen (once), so the next one');
    await c.flushEvents();
    expect(h.eventTypes, ['impression a']);
    c.unblock(); // more unblocks than blocks are harmless
    expect(c.isPaused, isFalse);
  });

  test('clicks: report, close, run the action, tell the app', () async {
    final buttons = [
      {'id': 'go', 'text': 'Go', 'action': {'type': 'deep_link', 'url': 'amarpartner://challenge'}},
      {'id': 'web', 'text': 'Web', 'action': {'type': 'url', 'url': 'https://amarpartner.app/x'}},
      {'id': 'b2', 'text': 'B2', 'action': {'type': 'tags', 'tags': {'level': 'b2', 'old': ''}}},
    ];
    h.server.inApp = [
      for (final b in buttons)
        inAppMessage('m-${b['id']}', content: {'title': 'T', 'buttons': [b]}, frequency: {'type': 'every_session'}),
      inAppMessage('tap', content: {'title': 'T', 'click_action': {'type': 'custom'}}),
      inAppMessage('no-action', content: {'title': 'T'}),
    ];
    final c = await h.start();
    for (final b in ['go', 'web', 'b2']) {
      final m = c.current.value!;
      expect(m.id, 'm-$b');
      h.display();
      await c.click(m, m.content.buttons.single);
      expect(h.showing, isNull);
      c.check();
    }
    final tap = c.current.value!;
    h.display();
    await c.click(tap);
    expect(h.clicks.map((x) => '${x.messageId} ${x.buttonId} ${x.actionType} ${x.url}'), [
      'm-go go deep_link amarpartner://challenge',
      'm-web web url https://amarpartner.app/x',
      'm-b2 b2 tags null',
      'tap null custom null',
    ]);
    expect(h.opened, [Uri.parse('https://amarpartner.app/x')]);
    expect(h.tagsSet, [
      {'level': 'b2', 'old': ''}
    ]);

    c.check();
    final plain = c.current.value!;
    expect(plain.id, 'no-action');
    h.display();
    await c.click(plain); // no click_action: tapping the message does nothing
    expect(h.showing, 'no-action');
    expect(c.handleBack(), isTrue, reason: 'the back button closes it');
    expect(c.handleBack(), isFalse);

    await c.flushEvents();
    expect(h.eventTypes, [
      'impression m-go', 'click m-go go',
      'impression m-web', 'click m-web web',
      'impression m-b2', 'click m-b2 b2',
      'impression tap', 'click tap',
      'impression no-action', 'dismiss no-action',
    ]);
    final seqs = [for (final e in h.server.inAppEvents) e['seq'] as int];
    expect(seqs, List.of(seqs)..sort());
    expect(seqs.toSet().length, seqs.length);
  });

  test('offline: the cached list is used and events wait', () async {
    h.server.inApp = [inAppMessage('a', frequency: {'type': 'every_session'})];
    await h.start();
    h.display();

    final offline = InAppHarness(storage: h.storage)..now = h.now.add(const Duration(hours: 1));
    addTearDown(offline.controller.dispose);
    offline.server.offline = true;
    final c = await offline.start();
    expect(offline.showing, 'a');
    offline.display();
    await c.flushEvents();
    expect(c.pendingEvents, 2, reason: 'the first run never sent its impression either');

    offline.server.offline = false;
    await c.flushEvents();
    expect(offline.eventTypes, ['impression a', 'impression a']);
    expect(c.pendingEvents, 0);
  });

  test('an unchanged list is not downloaded again (ETag)', () async {
    h.server.inApp = [inAppMessage('a')];
    final c = await h.start();
    h.now = h.now.add(const Duration(minutes: 2));
    await c.refresh();
    expect(h.server.headers.last['If-None-Match'], '"v1"');
    expect(c.messages.single.id, 'a');

    await c.refresh(); // within a minute: no request
    expect(h.server.calls.where((x) => x.endsWith('in-app')).length, 2);

    h.server.inApp = [inAppMessage('b')];
    h.server.inAppEtag = '"v2"';
    await c.refresh(force: true);
    expect(c.messages.single.id, 'b');
  });

  test('messages this SDK cannot show are skipped', () async {
    h.server.inApp = [
      inAppMessage('new-layout', layout: 'sidebar', priority: 9),
      inAppMessage('new-action', priority: 9, content: {
        'title': 'T',
        'buttons': [
          {'id': 'x', 'text': 'X', 'action': {'type': 'share'}}
        ]
      }),
      inAppMessage('new-trigger', priority: 9, triggers: [
        [
          {'kind': 'weather', 'op': '=', 'value': 'rain'}
        ]
      ]),
      inAppMessage('new-frequency', priority: 9, frequency: {'type': 'hourly'}),
      inAppMessage('fine'),
    ];
    final c = await h.start();
    expect(c.messages.map((m) => m.id), ['fine']);
    expect(h.showing, 'fine');
  });

  test('before the device is registered nothing is fetched; registering fetches', () async {
    h.registered = false;
    h.server.inApp = [inAppMessage('a')];
    final c = await h.start();
    expect(h.server.calls, isEmpty);
    expect(h.showing, isNull);
    h.registered = true;
    await c.onRegistered();
    expect(h.showing, 'a');
  });

  test('a message the host cannot draw is skipped for the session', () async {
    h.server.inApp = [inAppMessage('image-only', priority: 2, content: {'image_url': 'https://x/a.png'}), inAppMessage('text')];
    final c = await h.start();
    expect(h.showing, 'image-only');
    c.didFail(c.current.value!);
    expect(h.showing, 'text');
    h.display();
    c.dismiss(c.current.value!);
    background(const Duration(minutes: 10));
    await Future<void>.delayed(Duration.zero);
    expect(h.showing, 'image-only', reason: 'tried again next session');
  });

  test('events: permanent refusals are dropped, other failures kept', () async {
    h.server.inApp = [inAppMessage('a', frequency: {'type': 'every_session'})];
    final c = await h.start();
    h.display();
    h.server.intercept = (method, path, body) => path.endsWith('/events') ? FakeServer.error(503, 'down') : null;
    await c.flushEvents();
    expect(c.pendingEvents, 1);
    h.server.intercept = (method, path, body) => path.endsWith('/events') ? FakeServer.error(422, 'invalid') : null;
    await c.flushEvents();
    expect(c.pendingEvents, 0);
    h.server.intercept = (method, path, body) => path.endsWith('/events') ? http.Response('', 401) : null;
    c.dismiss(c.current.value!);
    await c.flushEvents();
    expect(c.pendingEvents, 1, reason: 'kept until the device registers again');
  });

  test('a storage that fails does not stop in-app messages', () async {
    final broken = InAppHarness(storage: _BrokenStorage());
    addTearDown(broken.controller.dispose);
    broken.server.inApp = [inAppMessage('a')];
    final c = await broken.start();
    expect(broken.showing, 'a');
    broken.display();
    await c.flushEvents();
    expect(broken.eventTypes, ['impression a']);
  });
}

class _BrokenStorage extends MemoryDakStorage {
  @override
  Future<String?> read() async => throw Exception('keystore locked');

  @override
  Future<void> write(String v) async => throw Exception('keystore locked');
}
