import 'dart:async';
import 'dart:convert';

import 'package:dak_push/dak_push.dart';
import 'package:dak_push/src/api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A small stand-in for the Dak server that follows its rules: register by
/// token, update with the device secret, tags merge with null deleting.
class FakeServer {
  final devices = <String, Map<String, dynamic>>{};
  final requests = <({String method, String path, Map<String, dynamic> body})>[];
  final opened = <String>[];
  bool offline = false;

  /// In-app messages the server hands out, with their ETag.
  List<Map<String, dynamic>> inApp = [];
  String inAppEtag = '"v1"';
  final inAppEvents = <Map<String, dynamic>>[];

  /// Headers of every request, in order.
  final headers = <Map<String, String>>[];
  int _n = 0;

  /// Return a response to override the next matching request.
  http.Response? Function(String method, String path, Map<String, dynamic> body)? intercept;

  late final client = MockClient((req) async {
    if (offline) throw http.ClientException('no network');
    final body = req.body.isEmpty ? <String, dynamic>{} : jsonDecode(req.body) as Map<String, dynamic>;
    final path = req.url.path;
    requests.add((method: req.method, path: path, body: body));
    headers.add(req.headers);
    final forced = intercept?.call(req.method, path, body);
    if (forced != null) return forced;

    final parts = path.split('/'); // ['', 'v1', 'apps', appId, 'devices', id?, 'opened'?]
    if (req.method == 'POST' && parts.length == 5) {
      final existing = devices.entries.where((e) => e.value['token'] == body['token']).firstOrNull;
      final id = existing?.key ?? 'dev-${++_n}';
      final secret = 'secret-${++_n}';
      final d = existing?.value ?? {'tags': <String, String>{}};
      _apply(d, body);
      d['secret'] = secret;
      devices[id] = d;
      return _json(existing == null ? 201 : 200, {'device_id': id, 'device_secret': secret});
    }
    final id = parts[5];
    final d = devices[id];
    if (d == null || req.headers['Authorization'] != 'Device ${d['secret']}') {
      return _json(401, {'error': {'code': 'unauthorized', 'message': 'register again'}});
    }
    if (req.method == 'GET' && parts.length == 7 && parts[6] == 'in-app') {
      if (req.headers['If-None-Match'] == inAppEtag) return http.Response('', 304, headers: {'etag': inAppEtag});
      return _json(200, {'messages': inApp}, {'etag': inAppEtag});
    }
    if (req.method == 'POST' && parts.length == 8 && parts[7] == 'events') {
      final events = (body['events'] as List).cast<Map<String, dynamic>>();
      inAppEvents.addAll(events);
      return _json(200, {'accepted': events.length});
    }
    if (req.method == 'PATCH') {
      _apply(d, body);
      return _json(200, {'device': {}});
    }
    if (req.method == 'POST' && parts.length == 7) {
      opened.add(body['message_id'] as String);
      return http.Response('', 204);
    }
    return _json(404, {'error': {'code': 'not_found', 'message': ''}});
  });

  void _apply(Map<String, dynamic> d, Map<String, dynamic> body) {
    body.forEach((k, v) {
      if (k == 'tags') {
        final tags = d['tags'] as Map<String, String>;
        (v as Map<String, dynamic>).forEach((tk, tv) => tv == null ? tags.remove(tk) : tags[tk] = tv as String);
      } else {
        d[k] = v;
      }
    });
  }

  static http.Response _json(int status, Object body, [Map<String, String> extra = const {}]) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json', ...extra});

  static http.Response error(int status, String code) => _json(status, {'error': {'code': code, 'message': code}});

  List<String> get calls => [for (final r in requests) '${r.method} ${r.path.split('/').skip(4).join('/')}'];
}

class FakeMessaging implements DakMessaging {
  String? token = 'fcm-token-1';
  bool permission = false;
  bool grantOnRequest = true;
  DakNotification? initial;
  final tokenRefresh = StreamController<String>.broadcast();
  final opened = StreamController<DakNotification>.broadcast();
  final foreground = StreamController<DakNotification>.broadcast();

  @override
  Future<String?> getToken() async => token;

  @override
  Stream<String> get onTokenRefresh => tokenRefresh.stream;

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<bool> requestPermission() async => permission = grantOnRequest;

  @override
  Future<DakNotification?> getInitialNotification() async => initial;

  @override
  Stream<DakNotification> get onOpened => opened.stream;

  @override
  Stream<DakNotification> get onForeground => foreground.stream;

  @override
  Future<void> showInForegroundOnIOS(bool show) async {}
}

class FakePlatform implements DakPlatformInfo {
  String version = '8.0.2+533';

  @override
  String get platform => 'android';

  @override
  Future<String> appVersion() async => version;

  @override
  Future<String> osVersion() async => '14';

  @override
  String language() => 'bn';
}

class Harness {
  Harness({MemoryDakStorage? storage}) : storage = storage ?? MemoryDakStorage();

  final server = FakeServer();
  final messaging = FakeMessaging();
  final platform = FakePlatform();
  final MemoryDakStorage storage;
  DateTime now = DateTime(2026, 10, 20, 12);

  late final client = build();

  DakClient build() => DakClient(
        api: DakApi(baseUrl: 'https://push.test/', appId: 'app-1', client: server.client),
        messaging: messaging,
        storage: storage,
        platform: platform,
        retryDelays: const [], // tests call flush() instead of waiting
        clock: () => now,
      );
}

/// Lets queued microtasks and stream events run.
Future<void> settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// A Dak in-app message as the server sends it.
Map<String, dynamic> inAppMessage(
  String id, {
  String layout = 'modal',
  Map<String, dynamic>? content,
  List<Object?> triggers = const [],
  Map<String, dynamic> frequency = const {'type': 'once'},
  int priority = 0,
  String? startAt,
  String? endAt,
  int shown = 0,
  String? lastShownAt,
}) =>
    {
      'id': id,
      'layout': layout,
      'content': content ?? {'title': 'Title $id', 'body': 'Body $id'},
      'triggers': triggers,
      'frequency': frequency,
      'priority': priority,
      if (startAt != null) 'start_at': startAt,
      if (endAt != null) 'end_at': endAt,
      'updated_at': '2026-10-20T00:00:00Z',
      'shown': shown,
      if (lastShownAt != null) 'last_shown_at': lastShownAt,
    };

/// A DakInAppController against [FakeServer], with a device already
/// registered and a clock the test moves.
class InAppHarness {
  InAppHarness({MemoryDakStorage? storage, this.registered = true}) : storage = storage ?? MemoryDakStorage() {
    server.devices['dev-1'] = {'secret': 's1', 'tags': <String, String>{}};
  }

  final server = FakeServer();
  final MemoryDakStorage storage;
  bool registered;
  DateTime now = DateTime(2026, 10, 20, 12);
  final tagsSet = <Map<String, Object?>>[];
  final opened = <Uri>[];
  final clicks = <DakInAppClick>[];

  late final controller = DakInAppController(
    api: DakApi(baseUrl: 'https://push.test', appId: 'app-1', client: server.client),
    storage: storage,
    credentials: () => registered ? (deviceId: 'dev-1', secret: 's1') : null,
    setTags: (t) async => tagsSet.add(t),
    openUrl: (u) async {
      opened.add(u);
      return true;
    },
    eventDelay: null,
    clock: () => now,
  )..onClick.listen(clicks.add);

  /// Starts and attaches, like an app with the host in place.
  Future<DakInAppController> start({bool attach = true}) async {
    await controller.start();
    if (attach) controller.attach();
    return controller;
  }

  String? get showing => controller.current.value?.id;

  /// Shows what is current on screen (the host's part).
  String? display() {
    final m = controller.current.value;
    if (m != null) controller.didDisplay(m);
    return m?.id;
  }

  List<String> get eventTypes => [
        for (final e in server.inAppEvents) '${e['type']} ${e['message_id']}${e['button_id'] == null ? '' : ' ${e['button_id']}'}'
      ];
}
