import 'dart:async';
import 'dart:convert';

import 'package:dak_push/dak_push.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// An app with the in-app host in MaterialApp's builder, started from cached
/// messages (no network).
class App {
  App(this.h, this.navigator);
  final InAppHarness h;
  final GlobalKey<NavigatorState> navigator;
  int appTaps = 0;

  DakInAppController get c => h.controller;

  /// Sends the queued events and lists them as "type message [button]".
  Future<List<String>> events() async {
    h.registered = true;
    await c.flushEvents();
    return h.eventTypes;
  }
}

Future<App> pumpApp(WidgetTester tester, List<Map<String, dynamic>> messages, {DakImageLoader? imageLoader}) async {
  final h = InAppHarness(registered: false);
  h.storage.value = jsonEncode({'messages': messages});
  await h.controller.start();
  final app = App(h, GlobalKey<NavigatorState>());
  await tester.pumpWidget(MaterialApp(
    navigatorKey: app.navigator,
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal)),
    builder: (context, child) => DakInAppHost(controller: h.controller, imageLoader: imageLoader, child: child!),
    home: Scaffold(
      body: Center(child: ElevatedButton(onPressed: () => app.appTaps++, child: const Text('App button'))),
    ),
  ));
  await tester.pumpAndSettle();
  return app;
}

Map<String, dynamic> button(String id, Map<String, dynamic> action, {String? bg, String? fg}) => {
      'id': id,
      'text': 'Button $id',
      'action': action,
      if (bg != null) 'background_color': bg,
      if (fg != null) 'text_color': fg,
    };

Color? materialColor(WidgetTester tester, Finder inside) =>
    tester.widget<Material>(find.ancestor(of: inside, matching: find.byType(Material)).first).color;

void main() {
  testWidgets('modal: content and buttons; a button click closes it and reaches the app', (tester) async {
    final app = await pumpApp(tester, [
      inAppMessage('m', content: {
        'title': 'স্বাগতম',
        'body': 'আজকের topic: Travel',
        'background_color': '#FFFDE7',
        'buttons': [
          button('go', {'type': 'deep_link', 'url': 'amarpartner://travel'}),
          button('later', {'type': 'dismiss'}),
        ],
      }),
    ]);
    expect(find.byKey(const Key('dak-in-app-modal')), findsOneWidget);
    expect(find.text('স্বাগতম'), findsOneWidget);
    expect(find.text('আজকের topic: Travel'), findsOneWidget);
    expect(find.byKey(const Key('dak-in-app-close')), findsOneWidget);
    expect(materialColor(tester, find.text('স্বাগতম')), const Color(0xFFFFFDE7));
    // Two buttons sit side by side.
    expect(tester.getTopLeft(find.text('Button go')).dy, tester.getTopLeft(find.text('Button later')).dy);

    await tester.tap(find.text('Button go'));
    await tester.pumpAndSettle();
    expect(find.text('স্বাগতম'), findsNothing);
    expect(app.h.clicks.single.toString(), 'DakInAppClick(m, go, deep_link amarpartner://travel)');
    expect(await app.events(), ['impression m', 'click m go']);
  });

  testWidgets('modal: the X and a tap outside dismiss it', (tester) async {
    final app = await pumpApp(tester, [
      inAppMessage('a', priority: 1),
      inAppMessage('b'),
    ]);
    expect(find.text('Title a'), findsOneWidget);
    expect(app.appTaps, 0);
    await tester.tap(find.text('App button'), warnIfMissed: false);
    expect(app.appTaps, 0, reason: 'the backdrop covers the app');

    await tester.tap(find.byKey(const Key('dak-in-app-close')));
    await tester.pumpAndSettle();
    expect(find.text('Title a'), findsNothing);

    app.c.check();
    await tester.pumpAndSettle();
    expect(find.text('Title b'), findsOneWidget);
    await tester.tapAt(const Offset(4, 4)); // outside the card
    await tester.pumpAndSettle();
    expect(find.text('Title b'), findsNothing);
    expect(await app.events(), ['impression a', 'dismiss a', 'impression b', 'dismiss b']);
  });

  testWidgets('card: slides up from the bottom; three buttons stack; a tags button sets tags', (tester) async {
    final app = await pumpApp(tester, [
      inAppMessage('c', layout: 'card', content: {
        'title': 'Level',
        'buttons': [
          button('b1', {'type': 'tags', 'tags': {'level': 'b1'}}),
          button('b2', {'type': 'tags', 'tags': {'level': 'b2'}}),
          button('custom', {'type': 'custom'}),
        ],
      }),
    ]);
    expect(find.byKey(const Key('dak-in-app-card')), findsOneWidget);
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(tester.getBottomLeft(find.text('Button custom')).dy, greaterThan(screen.height / 2));
    expect(tester.getTopLeft(find.text('Button b2')).dy, greaterThan(tester.getTopLeft(find.text('Button b1')).dy));

    await tester.tap(find.text('Button b2'));
    await tester.pumpAndSettle();
    expect(find.text('Level'), findsNothing);
    expect(app.h.tagsSet, [
      {'level': 'b2'}
    ]);
    expect(await app.events(), ['impression c', 'click c b2']);
  });

  testWidgets('fullscreen: covers the app; no X when close_button is false', (tester) async {
    final app = await pumpApp(tester, [
      inAppMessage('f', layout: 'fullscreen', content: {
        'title': 'Full',
        'body': 'Screen',
        'close_button': false,
        'buttons': [button('ok', {'type': 'dismiss'})],
      }),
    ]);
    expect(find.byKey(const Key('dak-in-app-fullscreen')), findsOneWidget);
    expect(find.byKey(const Key('dak-in-app-close')), findsNothing);
    expect(tester.getSize(find.ancestor(of: find.text('Full'), matching: find.byType(Material)).last),
        tester.view.physicalSize / tester.view.devicePixelRatio);

    await tester.tap(find.text('Button ok'));
    await tester.pumpAndSettle();
    expect(find.text('Full'), findsNothing);
    expect(app.h.clicks.single.actionType, 'dismiss');
  });

  testWidgets('top banner: the app stays usable, a tap runs click_action', (tester) async {
    final app = await pumpApp(tester, [
      inAppMessage('t', layout: 'banner_top', content: {
        'title': 'New message',
        'body': 'From Rahim',
        'click_action': {'type': 'deep_link', 'url': 'amarpartner://inbox'},
      }),
    ]);
    expect(find.byKey(const Key('dak-in-app-banner_top')), findsOneWidget);
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(tester.getTopLeft(find.text('New message')).dy, lessThan(screen.height / 4));

    await tester.tap(find.text('App button'));
    expect(app.appTaps, 1);
    expect(find.text('New message'), findsOneWidget);

    await tester.tap(find.text('From Rahim'));
    await tester.pumpAndSettle();
    expect(find.text('New message'), findsNothing);
    expect(app.h.clicks.single.toString(), 'DakInAppClick(t, null, deep_link amarpartner://inbox)');
    expect(await app.events(), ['impression t', 'click t']);
  });

  testWidgets('banner: closes by itself after auto_dismiss_seconds', (tester) async {
    final app = await pumpApp(tester, [
      inAppMessage('t', layout: 'banner_top', content: {'title': 'Brief', 'auto_dismiss_seconds': 5}),
    ]);
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Brief'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('Brief'), findsNothing);
    expect(await app.events(), ['impression t', 'dismiss t']);
  });

  testWidgets('bottom banner: sits at the bottom, a swipe down dismisses it', (tester) async {
    final app = await pumpApp(tester, [
      inAppMessage('b', layout: 'banner_bottom', content: {'title': 'Down here', 'close_button': false}),
    ]);
    expect(find.byKey(const Key('dak-in-app-banner_bottom')), findsOneWidget);
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(tester.getTopLeft(find.text('Down here')).dy, greaterThan(screen.height * 3 / 4));
    expect(find.byKey(const Key('dak-in-app-close')), findsNothing);

    await tester.drag(find.text('Down here'), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.text('Down here'), findsNothing);
    expect(await app.events(), ['impression b', 'dismiss b']);
  });

  testWidgets('colours: the message’s own, or the app theme’s', (tester) async {
    final app = await pumpApp(tester, [
      inAppMessage('themed', priority: 1, content: {
        'title': 'Themed',
        'buttons': [button('x', {'type': 'dismiss'})],
      }),
      inAppMessage('coloured', content: {
        'title': 'Coloured',
        'title_color': '#112233',
        'buttons': [button('y', {'type': 'dismiss'}, bg: '#FF0000', fg: '#80FFFFFF')],
      }),
    ]);
    final scheme = Theme.of(tester.element(find.text('Themed'))).colorScheme;
    expect(materialColor(tester, find.text('Themed')), scheme.surface);
    expect(tester.widget<Text>(find.text('Themed')).style!.color, scheme.onSurface);
    final themedButton = tester.widget<FilledButton>(find.byKey(const Key('dak-in-app-button-x')));
    expect(themedButton.style!.backgroundColor!.resolve({}), scheme.primary);

    await tester.tap(find.text('Button x'));
    await tester.pumpAndSettle();
    app.c.check();
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text('Coloured')).style!.color, const Color(0xFF112233));
    final style = tester.widget<FilledButton>(find.byKey(const Key('dak-in-app-button-y'))).style!;
    expect(style.backgroundColor!.resolve({}), const Color(0xFFFF0000));
    expect(style.foregroundColor!.resolve({}), const Color(0x80FFFFFF));
  });

  testWidgets('images: loaded first; a failed one is left out, or the message skipped if it is only an image', (tester) async {
    final loaded = <String>[];
    var works = false;
    final app = await pumpApp(
      tester,
      [
        inAppMessage('only-image', priority: 2, content: {'image_url': 'https://cdn.test/only.png'}),
        inAppMessage('with-text', priority: 1, content: {'title': 'Text too', 'image_url': 'https://cdn.test/a.png'}),
        inAppMessage('good', layout: 'card', content: {'title': 'Good', 'image_url': 'https://cdn.test/good.png'}),
      ],
      imageLoader: (context, url) async {
        loaded.add(url);
        return works;
      },
    );
    expect(loaded, ['https://cdn.test/only.png', 'https://cdn.test/a.png']);
    expect(find.text('Text too'), findsOneWidget);
    expect(find.byKey(const Key('dak-in-app-image')), findsNothing);

    await tester.tap(find.byKey(const Key('dak-in-app-close')));
    await tester.pumpAndSettle();
    works = true;
    app.c.check();
    await tester.pumpAndSettle();
    expect(find.text('Good'), findsOneWidget);
    expect(find.byKey(const Key('dak-in-app-image')), findsOneWidget);
    expect(await app.events(), ['impression with-text', 'dismiss with-text', 'impression good']);
  });

  testWidgets('DakInAppBlock keeps messages off a critical screen', (tester) async {
    final app = await pumpApp(tester, [
      inAppMessage('a', priority: 1),
      inAppMessage('on-call-end', triggers: [
        [
          {'kind': 'custom', 'key': 'call', 'op': '=', 'value': 'ended'}
        ]
      ]),
    ]);
    expect(find.text('Title a'), findsOneWidget);

    unawaited(app.navigator.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => DakInAppBlock(controller: app.c, child: const Scaffold(body: Text('Call screen'))),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Call screen'), findsOneWidget);
    expect(find.text('Title a'), findsNothing, reason: 'hidden while the call screen is open');
    expect(app.c.isPaused, isTrue);

    app.c.addTriggers({'call': 'ended'});
    await tester.pumpAndSettle();
    expect(find.text('Title on-call-end'), findsNothing);

    app.navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(app.c.isPaused, isFalse);
    expect(find.text('Title on-call-end'), findsOneWidget);
    expect(await app.events(), ['impression a', 'impression on-call-end']);
  });

  testWidgets('pausing hides the message on screen; afterwards what is still due shows', (tester) async {
    final app = await pumpApp(tester, [
      inAppMessage('a', priority: 1, frequency: {'type': 'every_session'}),
      inAppMessage('b'),
    ]);
    expect(find.text('Title a'), findsOneWidget);
    app.c.setPaused(true);
    await tester.pumpAndSettle();
    expect(find.text('Title a'), findsNothing);
    app.c.setPaused(false);
    await tester.pumpAndSettle();
    expect(find.text('Title a'), findsNothing, reason: 'every_session: already seen this session');
    expect(find.text('Title b'), findsOneWidget);
    expect(await app.events(), ['impression a', 'impression b']);
  });
}
