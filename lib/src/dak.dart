import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'api.dart';
import 'background.dart';
import 'client.dart';
import 'messaging.dart';
import 'native.dart';
import 'notification.dart';
import 'platform_info.dart';
import 'storage.dart';

class DakOptions {
  const DakOptions({
    this.showInForegroundOnIOS = false,
    this.debugLogs = false,
    this.handleBackgroundMessages = true,
    this.shareTimezoneOffset = false,
    this.iosAppGroup,
    this.useFid = true,
  });

  /// iOS only: let the system show notifications while the app is open.
  /// (On Android an open app gets them through [Dak.onForeground].)
  final bool showInForegroundOnIOS;

  /// Print what the SDK does (debug builds only).
  final bool debugLogs;

  /// Register Dak's handler with FirebaseMessaging.onBackgroundMessage, so
  /// pushes that arrive while the app is in the background are reported as
  /// delivered (Android, and iOS silent pushes). Firebase keeps one handler
  /// per app: if your app has its own, pass false and call
  /// [Dak.handleBackgroundMessage] from it.
  final bool handleBackgroundMessages;

  /// Send the phone's UTC offset (only the offset, like +06:00) so pushes
  /// can go at the user's local time and respect quiet hours. Off by
  /// default; then the app's timezone is used.
  final bool shareTimezoneOffset;

  /// iOS: the App Group (like group.com.example.app) shared with your
  /// notification service extension, which reports deliveries and shows
  /// images and buttons. See the README.
  final String? iosAppGroup;

  /// Use Firebase Installation IDs when firebase_messaging is 17 or newer
  /// (registration tokens are deprecated there); tokens otherwise.
  final bool useFid;
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
  static final DakNative _native = MethodChannelDakNative();

  static DakClient get _c {
    final c = _client;
    if (c == null) throw StateError('Call Dak.init() first');
    return c;
  }

  /// Starts the SDK: gets the push token and registers the device. Safe to
  /// call more than once. Initializes Firebase if the app has not.
  static Future<void> init({
    required String appId,
    required String baseUrl,
    DakOptions options = const DakOptions(),
  }) async {
    if (_client != null) return;
    WidgetsFlutterBinding.ensureInitialized();
    if (Firebase.apps.isEmpty) await Firebase.initializeApp();
    if (options.handleBackgroundMessages) {
      FirebaseMessaging.onBackgroundMessage(dakBackgroundMessageHandler);
    }
    final messaging = FirebaseDakMessaging(useFid: options.useFid);
    if (options.showInForegroundOnIOS && defaultTargetPlatform == TargetPlatform.iOS) {
      await messaging.showInForegroundOnIOS(true);
    }
    final client = DakClient(
      api: DakApi(baseUrl: baseUrl, appId: appId),
      messaging: messaging,
      storage: SecureDakStorage(),
      platform: DefaultPlatformInfo(),
      native: _native,
      shareTimezoneOffset: options.shareTimezoneOffset,
      iosAppGroup: options.iosAppGroup,
      log: options.debugLogs && kDebugMode ? debugPrint : null,
    );
    _client = client;
    _lifecycle = _Lifecycle(client);
    WidgetsBinding.instance.addObserver(_lifecycle!);
    await client.start();
  }

  /// For an app with its own FirebaseMessaging.onBackgroundMessage handler
  /// (and DakOptions(handleBackgroundMessages: false)): call this from it,
  /// so Dak can report the delivery. It does not need [init].
  static Future<void> handleBackgroundMessage(RemoteMessage message) => reportDelivery(message.data);

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

  /// iOS: sets the app icon badge; pushes with badge_increment add to it
  /// (through the notification service extension). Android launchers count
  /// notifications themselves, so this does nothing there.
  static Future<void> setBadge(int count) => _c.setBadge(count);

  static Future<void> clearBadge() => _c.setBadge(0);

  /// Android: shows a message that arrived while the app was open the way
  /// it would have been shown in the background, buttons included.
  static Future<void> showNotification(DakNotification notification) => _native.show(notification.raw);

  /// Taps on notifications while the app was running in the background.
  /// [DakNotification.actionId] tells which button was tapped, if one was.
  static Stream<DakNotification> get onOpened => _c.onOpened;

  /// Messages that arrive while the app is open, silent ones too (not shown
  /// by the system on Android; show them yourself if you want).
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
