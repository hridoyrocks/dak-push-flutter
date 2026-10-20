import 'dart:async';
import 'dart:convert';

import 'api.dart';
import 'messaging.dart';
import 'notification.dart';
import 'platform_info.dart';
import 'storage.dart';

const kDakSdkVersion = '0.1.0';

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
    this.sdkVersion = kDakSdkVersion,
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
  final String sdkVersion;
  final Duration lastSeenInterval;
  final List<Duration> retryDelays;
  final DateTime Function() _now;
  final void Function(String) _log;

  // Saved state.
  String? _deviceId;
  String? _secret;
  String? _token;
  String? _externalId;
  String? _authHash;
  Map<String, String> _tags = {};
  bool _subscribed = true;
  Map<String, Object?> _reported = {};
  DateTime? _lastSeenSent;
  List<String> _opens = [];

  // Read at start.
  bool _permission = false;
  String _appVersion = '';
  String _osVersion = '';
  String _language = '';

  final _openedCtl = StreamController<DakNotification>.broadcast();
  final _foregroundCtl = StreamController<DakNotification>.broadcast();
  final _subs = <StreamSubscription<dynamic>>[];
  DakNotification? _initial;
  Future<void>? _running;
  bool _again = false;
  Timer? _retryTimer;
  int _failures = 0;
  bool _started = false;

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
    _appVersion = await platform.appVersion();
    _osVersion = await platform.osVersion();
    _language = platform.language();
    _permission = await messaging.hasPermission();
    try {
      _token = await messaging.getToken() ?? _token;
    } catch (e) {
      _log('dak: could not get an FCM token yet: $e');
    }
    _subs.add(messaging.onTokenRefresh.listen((t) {
      _token = t;
      unawaited(_save().then((_) => _syncQuietly()));
    }));
    _subs.add(messaging.onOpened.listen(_handleOpen));
    _subs.add(messaging.onForeground.listen(_foregroundCtl.add));
    _initial = await messaging.getInitialNotification();
    if (_initial?.id != null) _queueOpen(_initial!.id!);
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

  /// Call when the app comes back to the foreground: picks up permission
  /// changes made in system settings and keeps last_seen fresh.
  Future<void> onResume() async {
    if (!_started) return;
    _permission = await messaging.hasPermission();
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

  void _handleOpen(DakNotification n) {
    if (n.id != null) _queueOpen(n.id!);
    _openedCtl.add(n);
  }

  void _queueOpen(String id) {
    if (_opens.contains(id)) return;
    _opens = [..._opens, id];
    if (_opens.length > 50) _opens = _opens.sublist(_opens.length - 50);
    unawaited(_save().then((_) => _syncQuietly()));
  }

  // ---- sync

  Map<String, Object?> _desired() => {
        'token': _token,
        'platform': platform.platform,
        'app_version': _appVersion,
        'os_version': _osVersion,
        'sdk_version': sdkVersion,
        'language': _language,
        'push_permission': _permission,
        'subscribed': _subscribed,
        'external_id': _externalId,
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
        await _sendOpens();
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
      final reg = await api.register(body);
      _deviceId = reg.deviceId;
      _secret = reg.deviceSecret;
      _reported = desired;
      _lastSeenSent = _now();
      await _save();
      return;
    }

    final patch = <String, Object?>{};
    for (final f in ['token', 'platform', 'app_version', 'os_version', 'sdk_version', 'language', 'push_permission', 'subscribed']) {
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

  Future<void> _sendOpens() async {
    while (_opens.isNotEmpty && _deviceId != null && _secret != null) {
      final id = _opens.first;
      try {
        await api.opened(_deviceId!, _secret!, id);
      } on DakApiException catch (e) {
        if (!e.isPermanent && !e.isUnauthorized) rethrow;
      }
      _opens = _opens.sublist(1);
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
      _externalId = js['external_id'] as String?;
      _authHash = js['auth_hash'] as String?;
      _tags = (js['tags'] as Map?)?.map((k, v) => MapEntry(k as String, v as String)) ?? {};
      _subscribed = js['subscribed'] as bool? ?? true;
      _reported = (js['reported'] as Map?)?.cast<String, Object?>() ?? {};
      final seen = js['last_seen_sent'] as String?;
      _lastSeenSent = seen == null ? null : DateTime.tryParse(seen);
      _opens = (js['opens'] as List?)?.cast<String>() ?? [];
    } catch (e) {
      _log('dak: ignoring unreadable saved state: $e');
    }
  }

  Future<void> _save() => storage.write(jsonEncode({
        'v': 1,
        'device_id': _deviceId,
        'secret': _secret,
        'token': _token,
        'external_id': _externalId,
        'auth_hash': _authHash,
        'tags': _tags,
        'subscribed': _subscribed,
        'reported': _reported,
        'last_seen_sent': _lastSeenSent?.toIso8601String(),
        'opens': _opens,
      }));
}
