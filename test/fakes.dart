import 'dart:async';
import 'dart:convert';

import 'package:dak_push/dak_push.dart';
import 'package:dak_push/src/api.dart';
import 'package:dak_push/src/storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A small stand-in for the Dak server that follows its rules: register by
/// token (its tags replace the row's), update with the device secret (tags
/// merge, null deleting).
class FakeServer {
  final devices = <String, Map<String, dynamic>>{};
  final requests = <({String method, String path, Map<String, dynamic> body})>[];
  final opened = <String>[];
  final openedActions = <String?>[];
  final delivered = <String>[];
  bool offline = false;

  /// While set, requests wait for it (a slow network).
  Completer<void>? hold;

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
    if (hold != null) await hold!.future;
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
      if (body.containsKey('tags')) d['tags'] = <String, String>{};
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

  static http.Response _json(int status, Object body, [Map<String, String> extra = const {}]) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json', ...extra});

  static http.Response error(int status, String code) => _json(status, {'error': {'code': code, 'message': code}});

  static http.Response jsonError(int status, Map<String, Object?> error) => _json(status, {'error': error});

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

  /// When set, getPushToken waits for it (FID registration on a slow network).
  Future<void>? tokenDelay;

  @override
  Future<DakPushToken?> getPushToken() async {
    if (tokenDelay != null) await tokenDelay;
    return token == null ? null : DakPushToken(token!, type: tokenType);
  }

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
  String? directory;
  bool showWorks = true;

  /// Receipts the iOS extension kept, by App Group.
  final extensionKept = <String, List<String>>{};
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
  Future<bool> show(Map<String, String> data) async {
    shown.add(data);
    return showWorks;
  }

  @override
  Future<String?> storageDirectory() async => directory;

  @override
  Future<List<String>> extensionReceipts(String appGroup) async => List.of(extensionKept[appGroup] ?? const []);

  @override
  Future<void> removeExtensionReceipts(String appGroup, List<String> messageIds) async =>
      extensionKept[appGroup]?.removeWhere(messageIds.contains);
}

class Harness {
  Harness({MemoryDakStorage? storage, this.shareTimezoneOffset = false, this.iosAppGroup, this.installMarker})
      : storage = storage ?? MemoryDakStorage();

  final server = FakeServer();
  final messaging = FakeMessaging();
  final platform = FakePlatform();
  final native = FakeNative();
  final MemoryDakStorage storage;
  final bool shareTimezoneOffset;
  final String? iosAppGroup;
  final DakStateStore? installMarker;
  DateTime now = DateTime(2026, 10, 20, 12);
  final logs = <String>[];
  final warnings = <String>[];

  late final client = build();

  /// Starts the client and waits for its first sync, which start() no longer
  /// waits for.
  Future<void> start() async {
    await client.start();
    await client.firstSync;
  }

  DakClient build() => DakClient(
        api: DakApi(baseUrl: 'https://push.test/', appId: 'app-1', client: server.client),
        messaging: messaging,
        storage: storage,
        platform: platform,
        native: native,
        shareTimezoneOffset: shareTimezoneOffset,
        iosAppGroup: iosAppGroup,
        installMarker: installMarker,
        retryDelays: const [], // tests call flush() instead of waiting
        clock: () => now,
        log: logs.add,
        warn: warnings.add,
      );
}

/// A marker kept in memory, like the file deleted with the app.
class MemoryStateStore implements DakStateStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String v) async => value = v;
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
  InAppHarness({MemoryDakStorage? storage, this.registered = true, this.appState, this.urlSchemes = const {'https', 'http'}})
      : storage = storage ?? MemoryDakStorage() {
    server.devices['dev-1'] = {'secret': 's1', 'tags': <String, String>{}};
  }

  final server = FakeServer();
  final MemoryDakStorage storage;
  final Set<String> urlSchemes;
  bool registered;
  final AppLifecycleState? Function()? appState;
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
    urlSchemes: urlSchemes,
    eventDelay: null,
    appState: appState,
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

/// The error the iOS keychain gives before the first unlock since the phone
/// started.
PlatformException lockedError() => PlatformException(code: 'Unexpected security result code', message: 'Code: -25308');

/// A storage that fails while [locked], like the keychain of an iPhone that
/// has not been unlocked since it started; [gate] holds reads back.
class LockableStorage extends MemoryDakStorage {
  LockableStorage({this.locked = false});
  bool locked;
  Completer<void>? gate;
  int writes = 0;

  @override
  Future<String?> read() async {
    if (gate != null) await gate!.future;
    if (locked) throw lockedError();
    return value;
  }

  @override
  Future<void> write(String v) async {
    if (locked) throw lockedError();
    writes++;
    value = v;
  }

  @override
  Future<void> addReceipt(String messageId) async {
    if (locked) throw lockedError();
    return super.addReceipt(messageId);
  }

  @override
  Future<List<String>> readReceipts() async {
    if (locked) throw lockedError();
    return super.readReceipts();
  }

  @override
  Future<void> removeReceipts(Iterable<String> messageIds) async {
    if (locked) throw lockedError();
    return super.removeReceipts(messageIds);
  }

  @override
  Future<void> clear() async {
    if (locked) throw lockedError();
    return super.clear();
  }
}

/// The keychain as flutter_secure_storage 10 sees it on iOS: an item saved
/// with the old accessibility is found only by a legacy read, and blocks a
/// write until it is deleted.
class FakeKeychain implements DakKeychain {
  final items = <String, ({String value, bool legacy})>{};
  bool locked = false;

  void _check() {
    if (locked) throw lockedError();
  }

  @override
  Future<String?> read(String key) async {
    _check();
    final i = items[key];
    return i == null || i.legacy ? null : i.value;
  }

  @override
  Future<String?> readLegacy(String key) async {
    _check();
    final i = items[key];
    return i != null && i.legacy ? i.value : null;
  }

  @override
  Future<void> write(String key, String value) async {
    _check();
    if (items[key]?.legacy ?? false) {
      throw PlatformException(code: 'Unexpected security result code', message: 'Code: -25299');
    }
    items[key] = (value: value, legacy: false);
  }

  @override
  Future<void> delete(String key) async {
    _check();
    items.remove(key);
  }

  @override
  Future<Iterable<String>> keys() async {
    _check();
    return [for (final e in items.entries) if (!e.value.legacy) e.key];
  }
}
