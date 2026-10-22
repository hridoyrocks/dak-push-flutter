import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

import 'api.dart';
import 'buffered_broadcast.dart';
import 'messaging.dart';
import 'native.dart';
import 'notification.dart';
import 'platform_info.dart';
import 'storage.dart';

/// The SDK version reported to the server. A test checks that it matches
/// pubspec.yaml, the podspec and build.gradle.
const kDakSdkVersion = '0.4.0';

/// A problem the app has to fix, such as a wrong auth hash or a bad tag.
/// Network trouble never throws: changes are kept and sent later.
class DakException implements Exception {
  /// Creates an exception with [message] and the error that caused it.
  DakException(this.message, [this.cause]);

  /// What went wrong, for developers.
  final String message;

  /// The underlying error, usually a [DakApiException] from the server.
  final Object? cause;

  /// The server's error code, like `identity_verification_failed` or
  /// `invalid`, when the server refused the change.
  String? get code => switch (cause) { final DakApiException e => e.code, _ => null };

  /// The field the server refused, like `tags` or `external_id`, if it said.
  String? get field => switch (cause) { final DakApiException e => e.field, _ => null };

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
@internal
String receiptToken(String deviceSecret) => sha256.convert(utf8.encode(deviceSecret)).toString();

/// The SDK's logic: it keeps the state the app wants (token, user, tags,
/// permission) and the state the server last accepted, and sends the
/// difference whenever they differ. Everything is saved, so changes made
/// offline are sent on a later start.
@internal
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
    this.giveUpLoadingAfter = const Duration(minutes: 1),
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

  /// Waits between retries of a failed sync, and of a saved state that could
  /// not be read; the last one repeats. Empty: no timers (tests).
  final List<Duration> retryDelays;

  /// A saved state that still cannot be read while the app is in the
  /// foreground this long after the first such try is given up, so the
  /// device can register again. (A locked iPhone is never in the
  /// foreground, so this is a broken keychain or keystore.)
  final Duration giveUpLoadingAfter;

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

  final _opened = BufferedBroadcast<DakNotification>();
  final _foregroundCtl = StreamController<DakNotification>.broadcast();
  final _registeredCtl = StreamController<void>.broadcast();
  final _deviceIdCtl = StreamController<String>.broadcast();
  final _errorsCtl = StreamController<DakException>.broadcast();
  final _loaded = Completer<void>();
  final _ready = Completer<void>();
  final _subs = <StreamSubscription<dynamic>>[];

  /// What came in before [_ready] (a token, a tap, a receipt): applied then,
  /// so the saved state cannot overwrite it.
  final _waiting = <void Function()>[];
  DakNotification? _initial;
  Future<void>? _starting;
  Future<void>? _connecting;
  Future<void>? _loading;
  Future<void>? _running;
  bool _again = false;
  Timer? _retryTimer;
  Timer? _loadTimer;
  int _failures = 0;
  int _loadFailures = 0;
  int _tokenEvents = 0;
  DateTime? _firstForegroundLoadFailure;
  bool _platformRead = false;
  bool _disposed = false;
  bool _reinstalled = false;
  DateTime? _notBefore;
  bool _reRegistered = false;
  String? _sharedWithExtension;

  String? get deviceId => _deviceId;
  String? get externalId => _externalId;
  Map<String, String> get tags => Map.unmodifiable(_tags);

  /// Taps on notifications. Taps that come while nobody listens are kept
  /// (20 at most) for the next listener.
  Stream<DakNotification> get onOpened => _opened.stream;
  Stream<DakNotification> get onForeground => _foregroundCtl.stream;

  /// Changes the server refused, also from syncs nobody awaited (a retry, a
  /// token refresh). Only the refused field is rolled back.
  Stream<DakException> get onError => _errorsCtl.stream;

  /// Completes once saved state is loaded, before any network call. If it
  /// cannot be read yet (a locked iPhone) this waits for a later try.
  Future<void> get loaded => _loaded.future;

  /// Completes when the first push token fetch and sync after [start] are
  /// done, whether or not they worked.
  Future<void> get firstSync => _connecting ?? Future.value();

  /// The device's id and secret, for the SDK's other parts (in-app messages).
  ({String deviceId, String secret})? get credentials =>
      _deviceId == null || _secret == null ? null : (deviceId: _deviceId!, secret: _secret!);

  /// Fires when the device is registered (again), so it now has credentials.
  Stream<void> get onRegistered => _registeredCtl.stream;

  /// The device id: the current one at once if there is one, then each new
  /// one (the saved id once it is read, the first registration, registering
  /// again after the server forgot the device). Never the same id twice in a
  /// row, and never null.
  Stream<String> get onDeviceId => Stream.multi((listener) {
        var last = _deviceId;
        if (last != null) listener.add(last);
        final sub = _deviceIdCtl.stream.listen((id) {
          if (id == last) return;
          last = id;
          listener.add(id);
        }, onDone: listener.close);
        listener.onCancel = sub.cancel;
      });

  /// The notification the user tapped to open the app, if any.
  DakNotification? get initialNotification => _initial;

  /// True when the saved state came from an earlier install and was dropped.
  bool get reinstalled => _reinstalled;

  /// Reads the saved state and the notification that opened the app, and
  /// returns. Getting the push token and syncing go on in the background
  /// ([firstSync]), so a slow network never holds the app's start.
  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    // Listen first; what comes while the state loads waits for it.
    void onError(Object e) => _log('dak: $e');
    _subs.add(messaging.onPushToken.listen(
        (t) => _whenReady(() {
              _tokenEvents++;
              _token = t.value;
              _tokenType = t.type;
              unawaited(_saveAndSync());
            }),
        onError: onError));
    _subs.add(messaging.onOpened.listen((n) => unawaited(_handleOpen(n)), onError: onError));
    _subs.add(native.onAction.listen((n) => unawaited(_handleOpen(n)), onError: onError));
    _subs.add(messaging.onForeground.listen((n) {
      final id = n.id;
      if (id != null) _whenReady(() => _queueReceipt(id));
      if (!_foregroundCtl.isClosed) _foregroundCtl.add(n);
    }, onError: onError));
    await _tryLoad();
    await _readPlatform();
    final launch = await _orElse(messaging.getInitialNotification, null, 'initial notification') ??
        await _orElse(native.initialAction, null, 'initial action');
    if (launch != null) {
      final initial = await _withIOSAction(launch);
      _initial = initial;
      final id = initial.id;
      if (id != null) _whenReady(() => _queueOpen(id, initial.actionId));
    }
    _connecting = _connect();
  }

  /// The network half of [start]. Never throws.
  Future<void> _connect() async {
    await _ready.future;
    if (_disposed) return;
    try {
      await _takeBackgroundReceipts();
      try {
        final seen = _tokenEvents;
        final t = await messaging.getPushToken();
        // A refresh that came meanwhile is newer.
        if (t != null && _tokenEvents == seen) {
          _token = t.value;
          _tokenType = t.type;
        }
      } catch (e) {
        _log('dak: could not get a push token yet: $e');
      }
      await _save();
    } catch (e) {
      _log('dak: $e');
    }
    await _syncQuietly();
  }

  /// Each detail on its own, so one broken plugin call costs only that one.
  /// Versions are cut to the server's 32 bytes.
  Future<void> _readPlatform() async {
    _appVersion = clampUtf8(await _orElse(platform.appVersion, '', 'app version'), 32);
    _osVersion = clampUtf8(await _orElse(platform.osVersion, '', 'OS version'), 32);
    _language = await _orElse(() async => platform.language(), '', 'language');
    _offset =
        shareTimezoneOffset ? await _orElse<int?>(() async => platform.utcOffsetMinutes(), null, 'UTC offset') : null;
    _permission = await _orElse(messaging.hasPermission, false, 'permission');
    _platformRead = true;
    _checkReady();
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

  /// Runs [f] once the saved state is loaded and the platform read.
  void _whenReady(void Function() f) => _ready.isCompleted ? f() : _waiting.add(f);

  void _checkReady() {
    if (_ready.isCompleted || !_loaded.isCompleted || !_platformRead) return;
    _ready.complete();
    final waiting = List.of(_waiting);
    _waiting.clear();
    for (final f in waiting) {
      f();
    }
  }

  Future<bool> requestPermission() async {
    final granted = await messaging.requestPermission();
    await _ready.future;
    _permission = granted;
    await _save();
    await _syncQuietly();
    return granted;
  }

  /// Links this device to your user. [authHash] is
  /// hex(HMAC-SHA256(external id, identity secret)), made by your server.
  Future<void> login(String externalId, {String? authHash}) async {
    if (externalId.isEmpty || _bytes(externalId) > 128 || externalId.contains('@')) {
      throw ArgumentError.value(externalId, 'externalId', 'use your own user id (1-128 characters, not an email)');
    }
    await _ready.future;
    _externalId = externalId;
    _authHash = authHash;
    await _save();
    await _sync();
  }

  /// Unlinks the user and removes the device's tags, so the next user of
  /// this phone starts without them. Push permission and the subscription
  /// stay.
  Future<void> logout() async {
    await _ready.future;
    _externalId = null;
    _authHash = null;
    _tags = {};
    await _save();
    await _sync();
  }

  /// Sets tags; a null or empty value removes the tag. Values are stored as
  /// strings (numbers and booleans are converted).
  Future<void> setTags(Map<String, Object?> changes) async {
    final values = <String, String>{};
    changes.forEach((k, v) {
      if (!_tagKey.hasMatch(k)) {
        throw ArgumentError.value(k, 'tag key', 'must be 1-64 of A-Z a-z 0-9 _ . : -');
      }
      if (v != null && v is! String && v is! num && v is! bool) {
        throw ArgumentError.value(v, k, 'tag values must be strings, numbers or booleans');
      }
      final s = v?.toString() ?? '';
      if (_bytes(s) > 255) throw ArgumentError.value(v, k, 'at most 255 bytes of UTF-8');
      values[k] = s;
    });
    await _ready.future;
    final next = Map.of(_tags);
    values.forEach((k, s) => s.isEmpty ? next.remove(k) : next[k] = s);
    if (next.length > 50) throw ArgumentError('a device can have at most 50 tags');
    _tags = next;
    await _save();
    await _sync();
  }

  Future<void> deleteTags(List<String> keys) => setTags({for (final k in keys) k: null});

  /// Opts this device out of (false) or back into (true) all pushes.
  Future<void> setSubscribed(bool subscribed) async {
    await _ready.future;
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
    if (_starting == null || _disposed) return;
    if (!_loaded.isCompleted) {
      await _tryLoad();
      if (!_loaded.isCompleted) _foregroundLoadFailed();
      if (!_loaded.isCompleted) return;
    }
    await _ready.future;
    _permission = await _orElse(messaging.hasPermission, _permission, 'permission');
    if (shareTimezoneOffset) {
      _offset = await _orElse<int?>(() async => platform.utcOffsetMinutes(), _offset, 'UTC offset');
    }
    await _takeBackgroundReceipts();
    await _syncQuietly();
  }

  /// Sends anything pending now (tests, or after connectivity returns).
  Future<void> flush() async {
    if (!_loaded.isCompleted) await _tryLoad();
    if (!_ready.isCompleted) return;
    await _syncQuietly();
  }

  Future<void> dispose() async {
    _disposed = true;
    _retryTimer?.cancel();
    _loadTimer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    await _opened.close();
    await _foregroundCtl.close();
    await _registeredCtl.close();
    await _deviceIdCtl.close();
    await _errorsCtl.close();
  }

  /// iOS with firebase_messaging 15/16: RemoteMessage has no action id, the
  /// plugin may have it.
  Future<DakNotification> _withIOSAction(DakNotification n) async {
    if (n.actionId != null || n.id == null || n.buttons.isEmpty) return n;
    final action = await native.takeAction(n.id!);
    return action == null ? n : n.withAction(action);
  }

  Future<void> _handleOpen(DakNotification tapped) async {
    var n = tapped;
    try {
      n = await _withIOSAction(tapped);
    } catch (e) {
      _log('dak: could not read the tapped button: $e');
    }
    final id = n.id;
    if (id != null) _whenReady(() => _queueOpen(id, n.actionId));
    _opened.add(n);
  }

  void _queueOpen(String id, String? action) {
    if (_opens.any((o) => o.id == id)) return;
    _opens = [..._opens, (id: id, action: action)];
    if (_opens.length > 50) _opens = _opens.sublist(_opens.length - 50);
    unawaited(_saveAndSync());
  }

  void _queueReceipt(String id) {
    if (_receipts.contains(id)) return;
    _receipts = [..._receipts, id];
    if (_receipts.length > 200) _receipts = _receipts.sublist(_receipts.length - 200);
    unawaited(_saveAndSync());
  }

  Future<void> _saveAndSync() async {
    try {
      await _save();
    } catch (e) {
      _log('dak: could not save: $e');
    }
    await _syncQuietly();
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
    await _ready.future;
    DakException? refused;
    final reverted = <String>{};
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
        final error = DakException(e.message, e);
        refused ??= error;
        if (!_errorsCtl.isClosed) _errorsCtl.add(error);
        // The server refused something the app set (a wrong auth hash, a bad
        // tag): go back to what it last accepted for that field alone, so
        // the rest (an opt-out above all) still gets through.
        final field = _revertible(e);
        if (field == null || !reverted.add(field)) break;
        _revert(field);
        await _save();
        _again = true;
      } catch (e) {
        _log('dak: sync failed, will retry: $e');
        _scheduleRetry();
        break;
      }
    }
    if (refused != null) throw refused;
  }

  /// The app-set field a refusal is about, if it can be rolled back.
  /// `subscribed` never is: the user's choice stays.
  static String? _revertible(DakApiException e) {
    if (e.code == 'identity_verification_failed') return 'external_id';
    return switch (e.field) {
      'external_id' || 'auth_hash' => 'external_id',
      'tags' => 'tags',
      _ => null,
    };
  }

  void _revert(String field) {
    switch (field) {
      case 'external_id':
        final id = _reported['external_id'];
        _externalId = id is String ? id : null;
        if (_externalId == null) _authHash = null;
      case 'tags':
        final tags = _reported['tags'];
        _tags = tags is Map ? tags.map((k, v) => MapEntry(k.toString(), v.toString())) : {};
    }
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
      if (!_registeredCtl.isClosed) _registeredCtl.add(null);
      _announceDeviceId();
      return;
    }

    final patch = <String, Object?>{};
    // A token is always sent with its type, which the server would otherwise
    // reset to "token".
    if (desired['token'] != _reported['token'] || desired['token_type'] != (_reported['token_type'] ?? 'token')) {
      patch['token'] = desired['token'];
      patch['token_type'] = desired['token_type'];
    }
    for (final f in [
      'platform',
      'app_version',
      'os_version',
      'sdk_version',
      'language',
      'push_permission',
      'subscribed',
      'utc_offset_minutes'
    ]) {
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

  /// Reads the saved state. A read that fails (the keychain of an iPhone
  /// not unlocked since it started) is tried again later, and nothing is
  /// saved or sent until one works, so the stored state is never replaced
  /// by an empty one.
  Future<void> _tryLoad() => _loading ??= _loadOnce().whenComplete(() => _loading = null);

  Future<void> _loadOnce() async {
    if (_loaded.isCompleted || _disposed) return;
    final String? raw;
    try {
      raw = await storage.read();
    } catch (e) {
      _log('dak: saved state not readable yet, will try again: $e');
      _scheduleLoadRetry();
      return;
    }
    _loadTimer?.cancel();
    var state = raw;
    if (await _fromEarlierInstall(state)) {
      _log('dak: the saved state is from an earlier install of the app; starting over');
      _reinstalled = true;
      state = null;
      try {
        await storage.clear();
      } catch (e) {
        _log('dak: could not clear the old state: $e');
      }
    }
    _restore(state);
    await _markInstall();
    _loadedNow();
  }

  /// The iOS keychain survives an uninstall, a file in the app's folder does
  /// not. State that names an install the marker does not know is old. State
  /// without an install id comes from SDK 0.3, before the marker: kept.
  Future<bool> _fromEarlierInstall(String? raw) async {
    final marker = installMarker;
    if (marker == null || raw == null || raw.isEmpty) return false;
    Object? saved;
    try {
      final js = jsonDecode(raw);
      if (js is Map) saved = js['install'];
    } catch (_) {
      return false;
    }
    if (saved is! String) return false;
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

  void _loadedNow() {
    if (_loaded.isCompleted) return;
    _loaded.complete();
    _announceDeviceId(); // the saved one, for listeners from before the load
    _checkReady();
  }

  void _announceDeviceId() {
    final id = _deviceId;
    if (id != null && !_deviceIdCtl.isClosed) _deviceIdCtl.add(id);
  }

  void _scheduleLoadRetry() {
    _loadTimer?.cancel();
    if (retryDelays.isEmpty || _disposed) return;
    final delay = retryDelays[_loadFailures < retryDelays.length ? _loadFailures : retryDelays.length - 1];
    _loadFailures++;
    _loadTimer = Timer(delay, () => unawaited(_tryLoad()));
  }

  /// The app is in the foreground, so the phone is unlocked, and the state
  /// still cannot be read: after [giveUpLoadingAfter], start over.
  void _foregroundLoadFailed() {
    final now = _now();
    final first = _firstForegroundLoadFailure ??= now;
    if (now.difference(first) < giveUpLoadingAfter) return;
    _log('dak: the saved state cannot be read; starting over');
    _loadTimer?.cancel();
    unawaited(_markInstall());
    _loadedNow();
  }

  void _restore(String? raw) {
    if (raw == null || raw.isEmpty) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (e) {
      _log('dak: ignoring unreadable saved state: $e');
      return;
    }
    if (decoded is! Map) return;
    String? text(Object? v) => v is String ? v : null;
    _deviceId = text(decoded['device_id']);
    _secret = text(decoded['secret']);
    _token = text(decoded['token']);
    _tokenType = text(decoded['token_type']) ?? 'token';
    _externalId = text(decoded['external_id']);
    _authHash = text(decoded['auth_hash']);
    final tags = decoded['tags'];
    _tags = tags is Map
        ? {
            for (final e in tags.entries)
              if (e.value is String) '${e.key}': e.value as String
          }
        : {};
    _subscribed = decoded['subscribed'] is bool ? decoded['subscribed'] as bool : true;
    final reported = decoded['reported'];
    _reported = reported is Map ? {for (final e in reported.entries) '${e.key}': e.value} : {};
    final seen = text(decoded['last_seen_sent']);
    _lastSeenSent = seen == null ? null : DateTime.tryParse(seen);
    final opens = decoded['opens'];
    _opens = [
      if (opens is List)
        for (final o in opens)
          // Version 1 kept only message ids.
          if (o is String)
            (id: o, action: null)
          else if (o is Map && o['id'] is String)
            (id: o['id'] as String, action: text(o['action'])),
    ];
    final receipts = decoded['receipts'];
    _receipts = [
      if (receipts is List)
        for (final r in receipts)
          if (r is String) r
    ];
    _install = text(decoded['install']);
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
        'opens': [
          for (final o in _opens) {'id': o.id, if (o.action != null) 'action': o.action}
        ],
        'receipts': _receipts,
        if (_install != null) 'install': _install,
      });
}
