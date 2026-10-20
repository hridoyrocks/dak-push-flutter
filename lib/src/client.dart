import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'api.dart';
import 'messaging.dart';
import 'native.dart';
import 'notification.dart';
import 'platform_info.dart';
import 'storage.dart';

const kDakSdkVersion = '0.2.0';

/// A problem the app has to fix, such as a wrong auth hash or a bad tag.
/// Network trouble never throws: changes are kept and sent later.
class DakException implements Exception {
  DakException(this.message, [this.cause]);
  final String message;
  final Object? cause;

  @override
  String toString() => 'DakException: $message';
}

final _tagKey = RegExp(r'^[A-Za-z0-9_.:-]{1,64}$');

/// hex(sha256(device secret)): what the iOS notification service extension
/// holds. It can report deliveries and nothing else.
String receiptToken(String deviceSecret) => sha256.convert(utf8.encode(deviceSecret)).toString();

/// The SDK's logic: it keeps the state the app wants (token, user, tags,
/// permission) and the state the server last accepted, and sends the
/// difference whenever they differ. Everything is saved, so changes made
/// offline are sent on a later start.
class DakClient {
  DakClient({
    required this.api,
    required this.messaging,
    required this.storage,
    required this.platform,
    this.native = const NoDakNative(),
    this.sdkVersion = kDakSdkVersion,
    this.shareTimezoneOffset = false,
    this.iosAppGroup,
    this.lastSeenInterval = const Duration(hours: 12),
    this.retryDelays = const [
      Duration(seconds: 5),
      Duration(seconds: 15),
      Duration(minutes: 1),
      Duration(minutes: 5),
    ],
    DateTime Function()? clock,
    void Function(String message)? log,
  })  : _now = clock ?? DateTime.now,
        _log = log ?? ((_) {});

  final DakApi api;
  final DakMessaging messaging;
  final DakStorage storage;
  final DakPlatformInfo platform;
  final DakNative native;
  final String sdkVersion;

  /// Send the phone's UTC offset, for local-time delivery and quiet hours.
  final bool shareTimezoneOffset;

  /// iOS: the App Group shared with the notification service extension.
  final String? iosAppGroup;
  final Duration lastSeenInterval;
  final List<Duration> retryDelays;
  final DateTime Function() _now;
  final void Function(String) _log;

  // Saved state.
  String? _deviceId;
  String? _secret;
  String? _token;
  String _tokenType = 'token';
  String? _externalId;
  String? _authHash;
  Map<String, String> _tags = {};
  bool _subscribed = true;
  Map<String, Object?> _reported = {};
  DateTime? _lastSeenSent;
  List<({String id, String? action})> _opens = [];
  List<String> _receipts = [];

  // Read at start.
  bool _permission = false;
  String _appVersion = '';
  String _osVersion = '';
  String _language = '';
  int? _offset;

  final _openedCtl = StreamController<DakNotification>.broadcast();
  final _foregroundCtl = StreamController<DakNotification>.broadcast();
  final _subs = <StreamSubscription<dynamic>>[];
  DakNotification? _initial;
  Future<void>? _running;
  bool _again = false;
  Timer? _retryTimer;
  int _failures = 0;
  bool _started = false;
  String? _sharedWithExtension;

  String? get deviceId => _deviceId;
  String? get externalId => _externalId;
  Map<String, String> get tags => Map.unmodifiable(_tags);
  Stream<DakNotification> get onOpened => _openedCtl.stream;
  Stream<DakNotification> get onForeground => _foregroundCtl.stream;

  /// The notification the user tapped to open the app, if any.
  DakNotification? get initialNotification => _initial;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _load();
    await _takeBackgroundReceipts();
    _appVersion = await platform.appVersion();
    _osVersion = await platform.osVersion();
    _language = platform.language();
    _offset = shareTimezoneOffset ? platform.utcOffsetMinutes() : null;
    _permission = await messaging.hasPermission();
    try {
      final t = await messaging.getPushToken();
      if (t != null) {
        _token = t.value;
        _tokenType = t.type;
      }
    } catch (e) {
      _log('dak: could not get a push token yet: $e');
    }
    _subs.add(messaging.onPushToken.listen((t) {
      _token = t.value;
      _tokenType = t.type;
      unawaited(_save().then((_) => _syncQuietly()));
    }));
    _subs.add(messaging.onOpened.listen((n) => unawaited(_handleOpen(n))));
    _subs.add(native.onAction.listen((n) => unawaited(_handleOpen(n))));
    _subs.add(messaging.onForeground.listen((n) {
      if (n.id != null) _queueReceipt(n.id!);
      _foregroundCtl.add(n);
    }));
    var initial = await messaging.getInitialNotification() ?? await native.initialAction();
    if (initial != null) {
      initial = await _withIOSAction(initial);
      _initial = initial;
      if (initial.id != null) _queueOpen(initial.id!, initial.actionId);
    }
    await _save();
    await _syncQuietly();
  }

  Future<bool> requestPermission() async {
    _permission = await messaging.requestPermission();
    await _save();
    await _syncQuietly();
    return _permission;
  }

  /// Links this device to your user. [authHash] is
  /// hex(HMAC-SHA256(external id, identity secret)), made by your server.
  Future<void> login(String externalId, {String? authHash}) async {
    if (externalId.isEmpty || externalId.length > 128 || externalId.contains('@')) {
      throw ArgumentError.value(externalId, 'externalId', 'use your own user id (1-128 characters, not an email)');
    }
    _externalId = externalId;
    _authHash = authHash;
    await _save();
    await _sync();
  }

  Future<void> logout() async {
    _externalId = null;
    _authHash = null;
    await _save();
    await _sync();
  }

  /// Sets tags; a null or empty value removes the tag. Values are stored as
  /// strings (numbers and booleans are converted).
  Future<void> setTags(Map<String, Object?> changes) async {
    final next = Map.of(_tags);
    changes.forEach((k, v) {
      if (!_tagKey.hasMatch(k)) {
        throw ArgumentError.value(k, 'tag key', 'must be 1-64 of A-Z a-z 0-9 _ . : -');
      }
      if (v != null && v is! String && v is! num && v is! bool) {
        throw ArgumentError.value(v, k, 'tag values must be strings, numbers or booleans');
      }
      final s = v?.toString() ?? '';
      if (s.length > 255) throw ArgumentError.value(v, k, 'at most 255 characters');
      if (s.isEmpty) {
        next.remove(k);
      } else {
        next[k] = s;
      }
    });
    if (next.length > 50) throw ArgumentError('a device can have at most 50 tags');
    _tags = next;
    await _save();
    await _sync();
  }

  Future<void> deleteTags(List<String> keys) => setTags({for (final k in keys) k: null});

  /// Opts this device out of (false) or back into (true) all pushes.
  Future<void> setSubscribed(bool subscribed) async {
    _subscribed = subscribed;
    await _save();
    await _sync();
  }

  /// iOS: sets the app icon badge; later badge_increment pushes add to it.
  Future<void> setBadge(int count) => native.setBadge(count < 0 ? 0 : count, appGroup: iosAppGroup);

  /// Call when the app comes back to the foreground: picks up permission
  /// changes made in system settings, receipts from the background, a new
  /// UTC offset, and keeps last_seen fresh.
  Future<void> onResume() async {
    if (!_started) return;
    _permission = await messaging.hasPermission();
    if (shareTimezoneOffset) _offset = platform.utcOffsetMinutes();
    await _takeBackgroundReceipts();
    await _syncQuietly();
  }

  /// Sends anything pending now (tests, or after connectivity returns).
  Future<void> flush() => _syncQuietly();

  Future<void> dispose() async {
    _retryTimer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    await _openedCtl.close();
    await _foregroundCtl.close();
  }

  /// iOS with firebase_messaging 15/16: RemoteMessage has no action id, the
  /// plugin may have it.
  Future<DakNotification> _withIOSAction(DakNotification n) async {
    if (n.actionId != null || n.id == null || n.buttons.isEmpty) return n;
    final action = await native.takeAction(n.id!);
    return action == null ? n : n.withAction(action);
  }

  Future<void> _handleOpen(DakNotification n) async {
    n = await _withIOSAction(n);
    if (n.id != null) _queueOpen(n.id!, n.actionId);
    _openedCtl.add(n);
  }

  void _queueOpen(String id, String? action) {
    if (_opens.any((o) => o.id == id)) return;
    _opens = [..._opens, (id: id, action: action)];
    if (_opens.length > 50) _opens = _opens.sublist(_opens.length - 50);
    unawaited(_save().then((_) => _syncQuietly()));
  }

  void _queueReceipt(String id) {
    if (_receipts.contains(id)) return;
    _receipts = [..._receipts, id];
    if (_receipts.length > 200) _receipts = _receipts.sublist(_receipts.length - 200);
    unawaited(_save().then((_) => _syncQuietly()));
  }

  /// Picks up receipts the background handler saved.
  Future<void> _takeBackgroundReceipts() async {
    try {
      final raw = await storage.readReceipts();
      if (raw == null || raw.isEmpty) return;
      await storage.writeReceipts('');
      final ids = (jsonDecode(raw) as List).cast<String>();
      for (final id in ids) {
        if (!_receipts.contains(id)) _receipts = [..._receipts, id];
      }
      await _save();
    } catch (e) {
      _log('dak: ignoring unreadable receipts: $e');
    }
  }

  // ---- sync

  Map<String, Object?> _desired() => {
        'token': _token,
        'token_type': _tokenType,
        'platform': platform.platform,
        'app_version': _appVersion,
        'os_version': _osVersion,
        'sdk_version': sdkVersion,
        'language': _language,
        'push_permission': _permission,
        'subscribed': _subscribed,
        'external_id': _externalId,
        'utc_offset_minutes': _offset,
        'tags': Map<String, String>.of(_tags),
      };

  Future<void> _syncQuietly() async {
    try {
      await _sync();
    } catch (e) {
      _log('dak: $e');
    }
  }

  /// Runs one sync at a time; a change made during a sync triggers another
  /// round, and every caller waits for the round that includes its change.
  Future<void> _sync() {
    _again = true;
    return _running ??= _loop().whenComplete(() => _running = null);
  }

  Future<void> _loop() async {
    Object? permanent;
    var reverted = false;
    while (_again) {
      _again = false;
      try {
        await _syncOnce();
        await _shareWithExtension();
        await _sendOpens();
        await _sendReceipts();
        _failures = 0;
        _retryTimer?.cancel();
      } on DakApiException catch (e) {
        if (!e.isPermanent) {
          _scheduleRetry();
          break;
        }
        permanent = DakException(e.message, e);
        if (reverted) break;
        // The server refused what the app set (bad auth hash, bad tag): go
        // back to what it last accepted so the rest still gets through.
        reverted = true;
        _revertAppState();
        await _save();
        _again = true;
      } catch (e) {
        _log('dak: sync failed, will retry: $e');
        _scheduleRetry();
        break;
      }
    }
    if (permanent != null) throw permanent;
  }

  void _revertAppState() {
    _externalId = _reported['external_id'] as String?;
    if (_externalId == null) _authHash = null;
    final tags = _reported['tags'];
    _tags = tags is Map ? tags.map((k, v) => MapEntry(k.toString(), v.toString())) : {};
    _subscribed = _reported['subscribed'] as bool? ?? true;
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    if (retryDelays.isEmpty) return;
    final delay = retryDelays[_failures < retryDelays.length ? _failures : retryDelays.length - 1];
    _failures++;
    _retryTimer = Timer(delay, () => unawaited(_syncQuietly()));
  }

  Future<void> _syncOnce() async {
    final desired = _desired();
    if (_token == null) return; // nothing to register until FCM gives a token

    if (_deviceId == null || _secret == null) {
      final body = Map<String, Object?>.of(desired);
      if (_externalId == null) {
        body.remove('external_id');
      } else {
        body['auth_hash'] = _authHash;
      }
      if (_offset == null) body.remove('utc_offset_minutes');
      final reg = await api.register(body);
      _deviceId = reg.deviceId;
      _secret = reg.deviceSecret;
      _reported = desired;
      _lastSeenSent = _now();
      await _save();
      return;
    }

    final patch = <String, Object?>{};
    // A token is always sent with its type, which the server would otherwise
    // reset to "token".
    if (desired['token'] != _reported['token'] || desired['token_type'] != (_reported['token_type'] ?? 'token')) {
      patch['token'] = desired['token'];
      patch['token_type'] = desired['token_type'];
    }
    for (final f in ['platform', 'app_version', 'os_version', 'sdk_version', 'language', 'push_permission', 'subscribed', 'utc_offset_minutes']) {
      if (desired[f] != _reported[f]) patch[f] = desired[f];
    }
    if (desired['external_id'] != _reported['external_id']) {
      patch['external_id'] = desired['external_id'];
      if (_externalId != null) patch['auth_hash'] = _authHash;
    }
    final want = desired['tags'] as Map<String, String>;
    final had = (_reported['tags'] as Map?)?.cast<String, Object?>() ?? const {};
    final tagChanges = <String, Object?>{};
    want.forEach((k, v) {
      if (had[k] != v) tagChanges[k] = v;
    });
    for (final k in had.keys) {
      if (!want.containsKey(k)) tagChanges[k] = null;
    }
    if (tagChanges.isNotEmpty) patch['tags'] = tagChanges;

    final stale = _lastSeenSent == null || _now().difference(_lastSeenSent!) >= lastSeenInterval;
    if (patch.isEmpty && !stale) return;

    try {
      await api.update(_deviceId!, _secret!, patch);
    } on DakApiException catch (e) {
      if (!e.isUnauthorized) rethrow;
      // The server no longer knows this device (deleted after a dead token or
      // a long absence): register again with the full state.
      _deviceId = null;
      _secret = null;
      _reported = {};
      await _save();
      _again = true;
      return;
    }
    _reported = desired;
    _lastSeenSent = _now();
    await _save();
  }

  /// iOS: gives the notification service extension what it needs to report
  /// deliveries. Only the receipt token, never the device secret.
  Future<void> _shareWithExtension() async {
    final group = iosAppGroup;
    if (group == null || _deviceId == null || _secret == null) return;
    final key = '$_deviceId:$_secret';
    if (_sharedWithExtension == key) return;
    await native.shareWithExtension(group, {
      'base_url': api.baseUrl,
      'app_id': api.appId,
      'device_id': _deviceId!,
      'receipt_token': receiptToken(_secret!),
    });
    _sharedWithExtension = key;
  }

  Future<void> _sendOpens() async {
    while (_opens.isNotEmpty && _deviceId != null && _secret != null) {
      final o = _opens.first;
      try {
        await api.opened(_deviceId!, _secret!, o.id, actionId: o.action);
      } on DakApiException catch (e) {
        if (!e.isPermanent && !e.isUnauthorized) rethrow;
      }
      _opens = _opens.sublist(1);
      await _save();
    }
  }

  Future<void> _sendReceipts() async {
    while (_receipts.isNotEmpty && _deviceId != null && _secret != null) {
      final batch = _receipts.take(50).toList();
      try {
        await api.delivered(_deviceId!, _secret!, batch);
      } on DakApiException catch (e) {
        if (!e.isPermanent && !e.isUnauthorized) rethrow;
      }
      _receipts = _receipts.skip(batch.length).toList();
      await _save();
    }
  }

  // ---- persistence

  Future<void> _load() async {
    final raw = await storage.read();
    if (raw == null || raw.isEmpty) return;
    try {
      final js = jsonDecode(raw) as Map<String, dynamic>;
      _deviceId = js['device_id'] as String?;
      _secret = js['secret'] as String?;
      _token = js['token'] as String?;
      _tokenType = js['token_type'] as String? ?? 'token';
      _externalId = js['external_id'] as String?;
      _authHash = js['auth_hash'] as String?;
      _tags = (js['tags'] as Map?)?.map((k, v) => MapEntry(k as String, v as String)) ?? {};
      _subscribed = js['subscribed'] as bool? ?? true;
      _reported = (js['reported'] as Map?)?.cast<String, Object?>() ?? {};
      final seen = js['last_seen_sent'] as String?;
      _lastSeenSent = seen == null ? null : DateTime.tryParse(seen);
      _opens = [
        for (final o in (js['opens'] as List?) ?? const [])
          // Version 1 kept only message ids.
          if (o is String) (id: o, action: null) else if (o is Map) (id: o['id'] as String, action: o['action'] as String?),
      ];
      _receipts = (js['receipts'] as List?)?.cast<String>() ?? [];
    } catch (e) {
      _log('dak: ignoring unreadable saved state: $e');
    }
  }

  Future<void> _save() => storage.write(jsonEncode({
        'v': 2,
        // For the background handler, which has no DakClient.
        'base_url': api.baseUrl,
        'app_id': api.appId,
        'device_id': _deviceId,
        'secret': _secret,
        'token': _token,
        'token_type': _tokenType,
        'external_id': _externalId,
        'auth_hash': _authHash,
        'tags': _tags,
        'subscribed': _subscribed,
        'reported': _reported,
        'last_seen_sent': _lastSeenSent?.toIso8601String(),
        'opens': [for (final o in _opens) {'id': o.id, if (o.action != null) 'action': o.action}],
        'receipts': _receipts,
      }));
}
