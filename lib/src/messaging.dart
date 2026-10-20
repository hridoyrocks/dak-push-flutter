import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'notification.dart';

/// What the server sends pushes to: an FCM registration token, or (with
/// firebase_messaging 17+) a Firebase Installation ID.
class DakPushToken {
  const DakPushToken(this.value, {this.type = 'token'});

  final String value;

  /// "token" or "fid".
  final String type;

  @override
  bool operator ==(Object other) => other is DakPushToken && other.value == value && other.type == type;

  @override
  int get hashCode => Object.hash(value, type);

  @override
  String toString() => 'DakPushToken($type)';
}

/// The parts of Firebase Messaging the SDK uses, behind an interface so the
/// SDK can be tested without Firebase.
abstract class DakMessaging {
  /// The current push target, or null if FCM has none yet.
  Future<DakPushToken?> getPushToken();

  /// New push targets (token refresh, FID registration).
  Stream<DakPushToken> get onPushToken;

  /// Whether the user currently allows notifications.
  Future<bool> hasPermission();

  /// Shows the system prompt (iOS, Android 13+) and returns the answer.
  Future<bool> requestPermission();

  /// The notification the user tapped to launch the app, if any.
  Future<DakNotification?> getInitialNotification();

  /// Taps on notifications while the app was in the background.
  Stream<DakNotification> get onOpened;

  /// Messages that arrive while the app is open (also silent ones).
  Stream<DakNotification> get onForeground;

  /// iOS: show notifications even while the app is open.
  Future<void> showInForegroundOnIOS(bool show);
}

/// Gets a Firebase Installation ID through firebase_messaging 17's
/// `register()` and `onRegistered`. Returns null on 15 and 16, which do not
/// have them, or if registration does not finish within [timeout].
///
/// [fm] is a FirebaseMessaging; it is dynamic so the SDK builds against all
/// three versions.
@visibleForTesting
Future<String?> registerFid(dynamic fm, {Duration timeout = const Duration(seconds: 15)}) async {
  final Stream<String> registered;
  try {
    // ignore: avoid_dynamic_calls
    registered = fm.onRegistered as Stream<String>;
  } on NoSuchMethodError {
    return null;
  }
  final first = registered.first.timeout(timeout);
  try {
    // ignore: avoid_dynamic_calls
    await (fm.register() as Future<void>);
  } on NoSuchMethodError {
    unawaited(first.then((_) {}, onError: (_) {}));
    return null;
  }
  try {
    return await first;
  } on TimeoutException {
    return null;
  }
}

/// Later FIDs from firebase_messaging 17, or null before 17.
@visibleForTesting
Stream<String>? fidUpdates(dynamic fm) {
  try {
    // ignore: avoid_dynamic_calls
    return fm.onRegistered as Stream<String>;
  } on NoSuchMethodError {
    return null;
  }
}

/// The tapped notification action on iOS, which firebase_messaging 17 adds
/// to RemoteMessage; null before 17 and for a tap on the notification itself.
@visibleForTesting
String? actionIdentifierOf(dynamic message) {
  try {
    // ignore: avoid_dynamic_calls
    final v = message.actionIdentifier as String?;
    // The system's ids for a plain tap and for a swipe away.
    if (v == null || v.startsWith('com.apple.')) return null;
    return v;
  } on NoSuchMethodError {
    return null;
  }
}

class FirebaseDakMessaging implements DakMessaging {
  FirebaseDakMessaging({this.useFid = true});

  /// Use Firebase Installation IDs when firebase_messaging has them (17+).
  final bool useFid;

  FirebaseMessaging get _fm => FirebaseMessaging.instance;

  static DakNotification convert(RemoteMessage m) => DakNotification.fromData(
        m.data,
        title: m.notification?.title,
        body: m.notification?.body,
        imageUrl: m.notification?.android?.imageUrl ?? m.notification?.apple?.imageUrl,
        actionId: actionIdentifierOf(m),
      );

  static bool _allowed(AuthorizationStatus s) =>
      s == AuthorizationStatus.authorized || s == AuthorizationStatus.provisional;

  // firebase_messaging 17 deprecates registration tokens in favour of
  // register()/onRegistered (Firebase Installation IDs). register() does not
  // exist before 17, so it is looked up at run time and the SDK falls back to
  // tokens on 15 and 16 (or if registration fails). Dak's server accepts both.
  @override
  Future<DakPushToken?> getPushToken() async {
    if (useFid) {
      try {
        final fid = await registerFid(_fm);
        if (fid != null && fid.isNotEmpty) return DakPushToken(fid, type: 'fid');
      } catch (_) {
        // Registration failed (no network, no APNs token yet): use a token.
      }
    }
    // ignore: deprecated_member_use
    final token = await _fm.getToken();
    return token == null ? null : DakPushToken(token);
  }

  @override
  Stream<DakPushToken> get onPushToken {
    final fids = useFid ? fidUpdates(_fm) : null;
    if (fids != null) return fids.map((f) => DakPushToken(f, type: 'fid'));
    // ignore: deprecated_member_use
    return _fm.onTokenRefresh.map(DakPushToken.new);
  }

  @override
  Future<bool> hasPermission() async => _allowed((await _fm.getNotificationSettings()).authorizationStatus);

  @override
  Future<bool> requestPermission() async =>
      _allowed((await _fm.requestPermission(alert: true, badge: true, sound: true)).authorizationStatus);

  @override
  Future<DakNotification?> getInitialNotification() async {
    final m = await _fm.getInitialMessage();
    return m == null ? null : convert(m);
  }

  @override
  Stream<DakNotification> get onOpened => FirebaseMessaging.onMessageOpenedApp.map(convert);

  @override
  Stream<DakNotification> get onForeground => FirebaseMessaging.onMessage.map(convert);

  @override
  Future<void> showInForegroundOnIOS(bool show) =>
      _fm.setForegroundNotificationPresentationOptions(alert: show, badge: show, sound: show);
}
