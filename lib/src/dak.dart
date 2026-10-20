import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'api.dart';
import 'client.dart';
import 'messaging.dart';
import 'notification.dart';
import 'platform_info.dart';
import 'storage.dart';

class DakOptions {
  const DakOptions({this.showInForegroundOnIOS = false, this.debugLogs = false});

  /// iOS only: let the system show notifications while the app is open.
  /// (On Android an open app gets them through [Dak.onForeground].)
  final bool showInForegroundOnIOS;

  /// Print what the SDK does (debug builds only).
  final bool debugLogs;
}

/// The SDK's entry point.
///
/// ```dart
/// await Dak.init(appId: 'APP_ID', baseUrl: 'https://push.example.com');
/// ```
class Dak {
  Dak._();

  static DakClient? _client;
  static _Lifecycle? _lifecycle;

  static DakClient get _c {
    final c = _client;
    if (c == null) throw StateError('Call Dak.init() first');
    return c;
  }

  /// Starts the SDK: gets the FCM token and registers the device. Safe to
  /// call more than once. Initializes Firebase if the app has not.
  static Future<void> init({
    required String appId,
    required String baseUrl,
    DakOptions options = const DakOptions(),
  }) async {
    if (_client != null) return;
    WidgetsFlutterBinding.ensureInitialized();
    if (Firebase.apps.isEmpty) await Firebase.initializeApp();
    final messaging = FirebaseDakMessaging();
    if (options.showInForegroundOnIOS && defaultTargetPlatform == TargetPlatform.iOS) {
      await messaging.showInForegroundOnIOS(true);
    }
    final client = DakClient(
      api: DakApi(baseUrl: baseUrl, appId: appId),
      messaging: messaging,
      storage: SecureDakStorage(),
      platform: DefaultPlatformInfo(),
      log: options.debugLogs && kDebugMode ? debugPrint : null,
    );
    _client = client;
    _lifecycle = _Lifecycle(client);
    WidgetsBinding.instance.addObserver(_lifecycle!);
    await client.start();
  }

  /// Asks the user for notification permission (iOS, Android 13+).
  static Future<bool> requestPermission() => _c.requestPermission();

  /// Links this device to your user id. With identity verification on (the
  /// default), [authHash] must come from your server.
  static Future<void> login(String externalId, {String? authHash}) =>
      _c.login(externalId, authHash: authHash);

  static Future<void> logout() => _c.logout();

  static Future<void> setTags(Map<String, Object?> tags) => _c.setTags(tags);

  static Future<void> deleteTags(List<String> keys) => _c.deleteTags(keys);

  static Future<void> setSubscribed(bool subscribed) => _c.setSubscribed(subscribed);

  /// Taps on notifications while the app was running in the background.
  static Stream<DakNotification> get onOpened => _c.onOpened;

  /// Messages that arrive while the app is open (not shown by the system on
  /// Android; show them yourself if you want).
  static Stream<DakNotification> get onForeground => _c.onForeground;

  /// The notification the user tapped to launch the app, if any. Use this
  /// instead of FirebaseMessaging.getInitialMessage, which only answers once.
  static DakNotification? get initialNotification => _c.initialNotification;

  static String? get deviceId => _client?.deviceId;
}

class _Lifecycle with WidgetsBindingObserver {
  _Lifecycle(this.client);
  final DakClient client;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(client.onResume());
  }
}
