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
  final openedActions = <String?>[];
  final delivered = <String>[];
  bool offline = false;
  int _n = 0;

  /// Return a response to override the next matching request.
  http.Response? Function(String method, String path, Map<String, dynamic> body)? intercept;

  late final client = MockClient((req) async {
    if (offline) throw http.ClientException('no network');
    final body = req.body.isEmpty ? <String, dynamic>{} : jsonDecode(req.body) as Map<String, dynamic>;
    final path = req.url.path;
    requests.add((method: req.method, path: path, body: body));
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
    if (req.method == 'PATCH') {
      _apply(d, body);
      return _json(200, {'device': {}});
    }
    if (req.method == 'POST' && parts.length == 7 && parts[6] == 'opened') {
      opened.add(body['message_id'] as String);
      openedActions.add(body['action_id'] as String?);
      return http.Response('', 204);
    }
    if (req.method == 'POST' && parts.length == 7 && parts[6] == 'delivered') {
      delivered.addAll((body['message_ids'] as List).cast<String>());
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

  static http.Response _json(int status, Object body) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  static http.Response error(int status, String code) => _json(status, {'error': {'code': code, 'message': code}});

  List<String> get calls => [for (final r in requests) '${r.method} ${r.path.split('/').skip(4).join('/')}'];
}

class FakeMessaging implements DakMessaging {
  String? token = 'fcm-token-1';
  String tokenType = 'token';
  bool permission = false;
  bool grantOnRequest = true;
  DakNotification? initial;
  final tokenRefresh = StreamController<String>.broadcast();
  final opened = StreamController<DakNotification>.broadcast();
  final foreground = StreamController<DakNotification>.broadcast();

  @override
  Future<DakPushToken?> getPushToken() async => token == null ? null : DakPushToken(token!, type: tokenType);

  @override
  Stream<DakPushToken> get onPushToken => tokenRefresh.stream.map((t) => DakPushToken(t, type: tokenType));

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
  int offset = 360;

  @override
  int utcOffsetMinutes() => offset;

  @override
  String get platform => 'android';

  @override
  Future<String> appVersion() async => version;

  @override
  Future<String> osVersion() async => '14';

  @override
  String language() => 'bn';
}

class FakeNative implements DakNative {
  DakNotification? initial;
  final actions = StreamController<DakNotification>.broadcast();
  final iosActions = <String, String>{};
  final shared = <({String group, Map<String, String> values})>[];
  int? badge;
  String? badgeGroup;
  final shown = <Map<String, String>>[];

  @override
  Future<DakNotification?> initialAction() async => initial;

  @override
  Stream<DakNotification> get onAction => actions.stream;

  @override
  Future<String?> takeAction(String messageId) async => iosActions.remove(messageId);

  @override
  Future<void> shareWithExtension(String appGroup, Map<String, String> values) async =>
      shared.add((group: appGroup, values: values));

  @override
  Future<void> setBadge(int count, {String? appGroup}) async {
    badge = count;
    badgeGroup = appGroup;
  }

  @override
  Future<void> show(Map<String, String> data) async => shown.add(data);
}

class Harness {
  Harness({MemoryDakStorage? storage, this.shareTimezoneOffset = false, this.iosAppGroup})
      : storage = storage ?? MemoryDakStorage();

  final server = FakeServer();
  final messaging = FakeMessaging();
  final platform = FakePlatform();
  final native = FakeNative();
  final MemoryDakStorage storage;
  final bool shareTimezoneOffset;
  final String? iosAppGroup;
  DateTime now = DateTime(2026, 10, 20, 12);

  late final client = build();

  DakClient build() => DakClient(
        api: DakApi(baseUrl: 'https://push.test/', appId: 'app-1', client: server.client),
        messaging: messaging,
        storage: storage,
        platform: platform,
        native: native,
        shareTimezoneOffset: shareTimezoneOffset,
        iosAppGroup: iosAppGroup,
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
