import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'api.dart';
import 'messaging.dart';
import 'native.dart';
import 'notification.dart';
import 'platform_info.dart';
import 'storage.dart';

const kDakSdkVersion = '0.3.0';

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

/// The server counts lengths in UTF-8 bytes.
int _bytes(String s) => utf8.encode(s).length;

/// [s] cut to at most [max] UTF-8 bytes, never inside a character.
@visibleForTesting
String clampUtf8(String s, int max) {
  if (_bytes(s) <= max) return s;
  final out = StringBuffer();
  var used = 0;
  for (final rune in s.runes) {
    final ch = String.fromCharCode(rune);
    final n = _bytes(ch);
    if (used + n > max) break;
    out.write(ch);
    used += n;
  }
  return out.toString();
}

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
    this.installMarker,
    DateTime Function()? clock,
    math.Random? random,
    void Function(String message)? log,
    void Function(String message)? warn,
  })  : _now = clock ?? DateTime.now,
        _random = random ?? math.Random(),
        _log = log ?? ((_) {}),
        _warn = warn ?? log ?? ((_) {});

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

  /// A file deleted with the app. The iOS keychain keeps the SDK's state
  /// after an uninstall; a missing marker tells that state belongs to an
  /// earlier install, which must not come back (its user, its tags).
  final DakStateStore? installMarker;
  final DateTime Function() _now;
  final math.Random _random;
  final void Function(String) _log;

  /// Setup problems the developer must see (debug builds).
  final void Function(String) _warn;

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
  String? _install;

  // Read at start.
  bool _permission = false;
  String _appVersion = '';
  String _osVersion = '';
  String _language = '';
  int? _offset;

  final _openedCtl = StreamController<DakNotification>.broadcast();
  final _foregroundCtl = StreamController<DakNotification>.broadcast();
  final _registeredCtl = StreamController<void>.broadcast();
  final _loaded = Completer<void>();
  final _subs = <StreamSubscription<dynamic>>[];
  DakNotification? _initial;
  Future<void>? _running;
  bool _again = false;
  Timer? _retryTimer;
  int _failures = 0;
  DateTime? _notBefore;
  bool _reRegistered = false;
  bool _started = false;
  bool _disposed = false;
  bool _reinstalled = false;
  String? _sharedWithExtension;

  String? get deviceId => _deviceId;
  String? get externalId => _externalId;
  Map<String, String> get tags => Map.unmodifiable(_tags);
  Stream<DakNotification> get onOpened => _openedCtl.stream;
  Stream<DakNotification> get onForeground => _foregroundCtl.stream;

  /// Completes once saved state is loaded, before any network call.
  Future<void> get loaded => _loaded.future;

  /// The device's id and secret, for the SDK's other parts (in-app messages).
  ({String deviceId, String secret})? get credentials =>
      _deviceId == null || _secret == null ? null : (deviceId: _deviceId!, secret: _secret!);

  /// Fires when the device is registered (again), so it now has credentials.
  Stream<void> get onRegistered => _registeredCtl.stream;

  /// The notification the user tapped to open the app, if any.
  DakNotification? get initialNotification => _initial;

  /// True when the saved state came from an earlier install and was dropped.
  bool get reinstalled => _reinstalled;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _load();
    _loaded.complete();
    await _takeBackgroundReceipts();
    _appVersion = clampUtf8(await _orElse(platform.appVersion, '', 'app version'), 32);
    _osVersion = clampUtf8(await _orElse(platform.osVersion, '', 'OS version'), 32);
    _language = await _orElse(() async => platform.language(), '', 'language');
    _offset =
        shareTimezoneOffset ? await _orElse<int?>(() async => platform.utcOffsetMinutes(), null, 'UTC offset') : null;
    _permission = await _orElse(messaging.hasPermission, false, 'permission');
    try {
      final t = await messaging.getPushToken();
      if (t != null) {
        _token = t.value;
        _tokenType = t.type;
      }
    } catch (e) {
      _log('dak: could not get a push token yet: $e');
    }
    void onError(Object e) => _log('dak: $e');
    _subs.add(messaging.onPushToken.listen((t) {
      _token = t.value;
      _tokenType = t.type;
      unawaited(_save().then((_) => _syncQuietly()));
    }, onError: onError));
    _subs.add(messaging.onOpened.listen((n) => unawaited(_handleOpen(n)), onError: onError));
    _subs.add(native.onAction.listen((n) => unawaited(_handleOpen(n)), onError: onError));
    _subs.add(messaging.onForeground.listen((n) {
      if (n.id != null) _queueReceipt(n.id!);
      if (!_foregroundCtl.isClosed) _foregroundCtl.add(n);
    }, onError: onError));
    var initial = await _orElse(messaging.getInitialNotification, null, 'initial notification') ??
        await _orElse(native.initialAction, null, 'initial action');
    if (initial != null) {
      initial = await _withIOSAction(initial);
      _initial = initial;
      if (initial.id != null) _queueOpen(initial.id!, initial.actionId);
    }
    await _save();
    await _syncQuietly();
  }

  /// Runs [f]; on an error logs it and returns [fallback], so one broken
  /// plugin call does not stop the SDK.
  Future<T> _orElse<T>(Future<T> Function() f, T fallback, String what) async {
    try {
      return await f();
    } catch (e) {
      _log('dak: could not read the $what: $e');
      return fallback;
    }
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
    if (externalId.isEmpty || _bytes(externalId) > 128 || externalId.contains('@')) {
      throw ArgumentError.value(externalId, 'externalId', 'use your own user id (1-128 characters, not an email)');
    }
    _externalId = externalId;
    _authHash = authHash;
    await _save();
    await _sync();
  }

  /// Unlinks the user and removes the device's tags, so the next user of
  /// this phone starts without them. Push permission and the subscription
  /// stay.
  Future<void> logout() async {
    _externalId = null;
    _authHash = null;
    _tags = {};
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
      if (_bytes(s) > 255) throw ArgumentError.value(v, k, 'at most 255 bytes of UTF-8');
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
    if (!_started || _disposed) return;
    _permission = await _orElse(messaging.hasPermission, _permission, 'permission');
    if (shareTimezoneOffset) {
      _offset = await _orElse<int?>(() async => platform.utcOffsetMinutes(), _offset, 'UTC offset');
    }
    await _takeBackgroundReceipts();
    await _syncQuietly();
  }

  /// Sends anything pending now (tests, or after connectivity returns).
  Future<void> flush() => _syncQuietly();

  Future<void> dispose() async {
    _disposed = true;
    _retryTimer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    await _openedCtl.close();
    await _foregroundCtl.close();
    await _registeredCtl.close();
  }

  /// iOS with firebase_messaging 15/16: RemoteMessage has no action id, the
  /// plugin may have it.
  Future<DakNotification> _withIOSAction(DakNotification n) async {
    if (n.actionId != null || n.id == null || n.buttons.isEmpty) return n;
    final action = await native.takeAction(n.id!);
    return action == null ? n : n.withAction(action);
  }

  Future<void> _handleOpen(DakNotification n) async {
    try {
      n = await _withIOSAction(n);
    } catch (e) {
      _log('dak: could not read the tapped button: $e');
    }
    if (n.id != null) _queueOpen(n.id!, n.actionId);
    if (!_openedCtl.isClosed) _openedCtl.add(n);
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

  /// Picks up receipts the background handler and the iOS notification
  /// service extension kept. They are deleted there only after they are
  /// saved here.
  Future<void> _takeBackgroundReceipts() async {
    try {
      final ids = await storage.readReceipts();
      final group = iosAppGroup;
      final fromExtension = group == null ? const <String>[] : await native.extensionReceipts(group);
      if (ids.isEmpty && fromExtension.isEmpty) return;
      for (final id in [...ids, ...fromExtension]) {
        if (!_receipts.contains(id)) _receipts = [..._receipts, id];
      }
      if (_receipts.length > 200) _receipts = _receipts.sublist(_receipts.length - 200);
      await _save();
      if (ids.isNotEmpty) await storage.removeReceipts(ids);
      if (fromExtension.isNotEmpty) await native.removeExtensionReceipts(group!, fromExtension);
    } catch (e) {
      _log('dak: could not read kept receipts: $e');
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
  /// While the server's Retry-After lasts, changes are only saved.
  Future<void> _sync() {
    if (_disposed) return Future.value();
    final wait = _notBefore;
    if (wait != null && _now().isBefore(wait)) {
      if (_retryTimer == null || !_retryTimer!.isActive) _retryAt(wait.difference(_now()));
      return Future.value();
    }
    _notBefore = null;
    _again = true;
    return _running ??= _loop().whenComplete(() => _running = null);
  }

  Future<void> _loop() async {
    Object? permanent;
    var reverted = false;
    _reRegistered = false;
    while (_again && !_disposed) {
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
          _scheduleRetry(e.retryAfter);
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

  /// The longest the SDK honours a Retry-After.
  static const maxRetryAfter = Duration(hours: 1);

  void _scheduleRetry([Duration? retryAfter]) {
    if (_disposed || retryDelays.isEmpty) return;
    final delay = retryDelay(_failures, retryAfter: retryAfter);
    _failures++;
    if (retryAfter != null) _notBefore = _now().add(delay);
    _retryAt(delay);
  }

  void _retryAt(Duration delay) {
    _retryTimer?.cancel();
    if (_disposed) return;
    _retryTimer = Timer(delay, () {
      _notBefore = null;
      unawaited(_syncQuietly());
    });
  }

  /// The wait before retry number [failures] + 1: the step from
  /// [retryDelays], of which a random half, so phones that failed together
  /// do not come back together; never shorter than the server's
  /// [retryAfter] (up to [maxRetryAfter]).
  @visibleForTesting
  Duration retryDelay(int failures, {Duration? retryAfter}) {
    final step = retryDelays[math.min(failures, retryDelays.length - 1)];
    final jittered = step * (0.5 + 0.5 * _random.nextDouble());
    if (retryAfter == null) return jittered;
    final asked = retryAfter > maxRetryAfter ? maxRetryAfter : retryAfter;
    return asked > jittered ? asked : jittered;
  }

  Future<void> _syncOnce() async {
    final desired = _desired();
    if (_token == null) return; // nothing to register until FCM gives a token

    if (_deviceId == null || _secret == null) {
      // The whole state, nulls included: the server may hand over an old row
      // for this token, whose user, tags and offset must not stay.
      final body = Map<String, Object?>.of(desired);
      if (_externalId != null) body['auth_hash'] = _authHash;
      final reg = await api.register(body);
      _deviceId = reg.deviceId;
      _secret = reg.deviceSecret;
      _reported = desired;
      _lastSeenSent = _now();
      await _save();
      _registeredCtl.add(null);
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
      if (!e.isUnauthorized || _reRegistered) rethrow;
      // The server no longer knows this device (deleted after a dead token or
      // a long absence): register again with the full state.
      await _forgetDevice();
      return;
    }
    _reported = desired;
    _lastSeenSent = _now();
    await _save();
  }

  /// Drops the device id and secret, so the next round registers again.
  /// Once per sync, so a server that keeps refusing cannot loop it.
  Future<void> _forgetDevice() async {
    _deviceId = null;
    _secret = null;
    _reported = {};
    _reRegistered = true;
    await _save();
    _again = true;
  }

  /// iOS: gives the notification service extension what it needs to report
  /// deliveries. Only the receipt token, never the device secret. A wrong
  /// App Group is reported once and does not stop the sync.
  Future<void> _shareWithExtension() async {
    final group = iosAppGroup;
    if (group == null || _deviceId == null || _secret == null) return;
    final key = '$_deviceId:$_secret';
    if (_sharedWithExtension == key) return;
    try {
      await native.shareWithExtension(group, {
        'base_url': api.baseUrl,
        'app_id': api.appId,
        'device_id': _deviceId!,
        'receipt_token': receiptToken(_secret!),
      });
    } catch (e) {
      _warn('dak: the notification service extension cannot report deliveries: $e');
    }
    _sharedWithExtension = key;
  }

  /// A 401 means the device must register again; the open is kept for the
  /// new registration.
  Future<void> _sendOpens() async {
    while (_opens.isNotEmpty && _deviceId != null && _secret != null) {
      final o = _opens.first;
      try {
        await api.opened(_deviceId!, _secret!, o.id, actionId: o.action);
      } on DakApiException catch (e) {
        if (e.isUnauthorized && !_reRegistered) return _forgetDevice();
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
        if (e.isUnauthorized && !_reRegistered) return _forgetDevice();
        if (!e.isPermanent && !e.isUnauthorized) rethrow;
      }
      _receipts = _receipts.skip(batch.length).toList();
      await _save();
    }
  }

  // ---- persistence

  Future<void> _load() async {
    final raw = await storage.read();
    Map<String, dynamic>? js;
    try {
      if (raw != null && raw.isNotEmpty) js = jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      _log('dak: ignoring unreadable saved state: $e');
    }
    if (await _fromEarlierInstall(js?['install'])) {
      _log('dak: the saved state is from an earlier install of the app; starting over');
      _reinstalled = true;
      js = null;
      try {
        await storage.clear();
      } catch (e) {
        _log('dak: could not clear the old state: $e');
      }
    }
    if (js != null) _read(js);
    await _markInstall();
  }

  /// The iOS keychain survives an uninstall, a file in the app's folder does
  /// not. State that names an install the marker does not know is old. State
  /// without an install id comes from SDK 0.3, before the marker: kept.
  Future<bool> _fromEarlierInstall(Object? saved) async {
    final marker = installMarker;
    if (marker == null || saved is! String) return false;
    try {
      return await marker.read() != saved;
    } catch (e) {
      _log('dak: could not read the install marker: $e');
      return false;
    }
  }

  Future<void> _markInstall() async {
    final marker = installMarker;
    if (marker == null) return;
    try {
      final current = await marker.read();
      if (current != null && current.isNotEmpty && (_install == null || _install == current)) {
        _install = current;
        return;
      }
      _install ??= _newInstallId();
      await marker.write(_install!);
    } catch (e) {
      _log('dak: could not write the install marker: $e');
    }
  }

  String _newInstallId() {
    final r = math.Random.secure();
    return [for (var i = 0; i < 16; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  }

  void _read(Map<String, dynamic> js) {
    try {
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
      _install = js['install'] as String?;
    } catch (e) {
      _log('dak: ignoring unreadable saved state: $e');
    }
  }

  /// Saving can fail (a locked keystore); the state then lives in memory
  /// until the next save works.
  Future<void> _save() async {
    try {
      await storage.write(_encode());
    } catch (e) {
      _log('dak: could not save the state: $e');
    }
  }

  String _encode() => jsonEncode({
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
        if (_install != null) 'install': _install,
      });
}
