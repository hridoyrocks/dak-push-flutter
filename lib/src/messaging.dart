import 'package:firebase_messaging/firebase_messaging.dart';

import 'notification.dart';

/// The parts of Firebase Messaging the SDK uses, behind an interface so the
/// SDK can be tested without Firebase.
abstract class DakMessaging {
  Future<String?> getToken();
  Stream<String> get onTokenRefresh;

  /// Whether the user currently allows notifications.
  Future<bool> hasPermission();

  /// Shows the system prompt (iOS, Android 13+) and returns the answer.
  Future<bool> requestPermission();

  /// The notification the user tapped to launch the app, if any.
  Future<DakNotification?> getInitialNotification();

  /// Taps on notifications while the app was in the background.
  Stream<DakNotification> get onOpened;

  /// Messages that arrive while the app is open.
  Stream<DakNotification> get onForeground;

  /// iOS: show notifications even while the app is open.
  Future<void> showInForegroundOnIOS(bool show);
}

class FirebaseDakMessaging implements DakMessaging {
  FirebaseMessaging get _fm => FirebaseMessaging.instance;

  static DakNotification _convert(RemoteMessage m) => DakNotification.fromData(
        m.data,
        title: m.notification?.title,
        body: m.notification?.body,
      );

  static bool _allowed(AuthorizationStatus s) =>
      s == AuthorizationStatus.authorized || s == AuthorizationStatus.provisional;

  // firebase_messaging 17 deprecates registration tokens in favour of
  // register()/onRegistered (Firebase Installation IDs). Tokens still work,
  // and register() does not exist before 17, so the SDK stays on tokens while
  // it supports 15 and 16. Dak's server already accepts FIDs (token_type "fid").
  @override
  // ignore: deprecated_member_use
  Future<String?> getToken() => _fm.getToken();

  @override
  // ignore: deprecated_member_use
  Stream<String> get onTokenRefresh => _fm.onTokenRefresh;

  @override
  Future<bool> hasPermission() async => _allowed((await _fm.getNotificationSettings()).authorizationStatus);

  @override
  Future<bool> requestPermission() async =>
      _allowed((await _fm.requestPermission(alert: true, badge: true, sound: true)).authorizationStatus);

  @override
  Future<DakNotification?> getInitialNotification() async {
    final m = await _fm.getInitialMessage();
    return m == null ? null : _convert(m);
  }

  @override
  Stream<DakNotification> get onOpened => FirebaseMessaging.onMessageOpenedApp.map(_convert);

  @override
  Stream<DakNotification> get onForeground => FirebaseMessaging.onMessage.map(_convert);

  @override
  Future<void> showInForegroundOnIOS(bool show) =>
      _fm.setForegroundNotificationPresentationOptions(alert: show, badge: show, sound: show);
}
