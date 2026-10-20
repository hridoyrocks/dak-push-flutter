import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'background.dart';
import 'client.dart';
import 'in_app/controller.dart';
import 'in_app/host.dart';
import 'in_app/model.dart';
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
    this.sessionTimeout = const Duration(minutes: 5),
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

  /// In-app messages: coming back after this long in the background starts a
  /// new session (session_count, every_session).
  final Duration sessionTimeout;
}

/// The SDK's entry point.
///
/// ```dart
/// await Dak.init(appId: 'APP_ID', baseUrl: 'https://push.example.com');
/// ```
class Dak {
  Dak._();

  static DakClient? _client;
  static DakInAppController? _inApp;
  static _Lifecycle? _lifecycle;
  static final DakNative _native = MethodChannelDakNative();

  static DakClient get _c {
    final c = _client;
    if (c == null) throw StateError('Call Dak.init() first');
    return c;
  }

  static DakInAppController get _i {
    final c = _inApp;
    if (c == null) throw StateError('Call Dak.init() first');
    return c;
  }

  /// Starts the SDK. Safe to call more than once. Initializes Firebase if
  /// the app has not. Call it before runApp, so the back button closes
  /// in-app messages first.
  ///
  /// It returns once the saved state and the notification that opened the
  /// app are read; getting the push token and registering the device go on
  /// in the background, so a slow network never holds the splash screen.
  /// Calls like [login] made meanwhile wait for the saved state, then sync.
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
    final api = DakApi(baseUrl: baseUrl, appId: appId);
    final log = options.debugLogs && kDebugMode ? debugPrint : null;
    final client = DakClient(
      api: api,
      messaging: messaging,
      storage: SecureDakStorage(),
      platform: DefaultPlatformInfo(),
      native: _native,
      shareTimezoneOffset: options.shareTimezoneOffset,
      iosAppGroup: options.iosAppGroup,
      log: log,
    );
    final inApp = DakInAppController(
      api: api,
      storage: SecureDakStorage(key: 'dak_push_in_app'),
      credentials: () => client.credentials,
      setTags: client.setTags,
      openUrl: (url) => launchUrl(url, mode: LaunchMode.externalApplication),
      sessionTimeout: options.sessionTimeout,
      appState: () => WidgetsBinding.instance.lifecycleState,
      log: log,
    );
    _client = client;
    _inApp = inApp;
    _lifecycle = _Lifecycle(client, inApp);
    WidgetsBinding.instance.addObserver(_lifecycle!);
    client.onRegistered.listen((_) => unawaited(inApp.onRegistered()));
    // In-app messages start from the cache as soon as the saved state is
    // read, without waiting for the network.
    unawaited(client.loaded.then((_) => inApp.start()));
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
  /// Taps that come before you listen are kept for your first listener.
  static Stream<DakNotification> get onOpened => _c.onOpened;

  /// Changes the server refused, such as a wrong auth hash or a bad tag,
  /// also from syncs that run in the background. Only the refused field is
  /// rolled back; the rest (an opt-out above all) is still sent.
  static Stream<DakException> get onError => _c.onError;

  /// Messages that arrive while the app is open, silent ones too (not shown
  /// by the system on Android; show them yourself if you want).
  static Stream<DakNotification> get onForeground => _c.onForeground;

  /// The notification the user tapped to launch the app, if any. Use this
  /// instead of FirebaseMessaging.getInitialMessage, which only answers once.
  static DakNotification? get initialNotification => _c.initialNotification;

  static String? get deviceId => _client?.deviceId;

  // ---- in-app messages

  /// For MaterialApp's builder: shows in-app messages above all pages.
  ///
  /// ```dart
  /// MaterialApp(builder: Dak.inAppBuilder, ...)
  /// ```
  static Widget inAppBuilder(BuildContext context, Widget? child) =>
      DakInAppHost(child: child ?? const SizedBox.shrink());

  /// Sets a trigger that in-app messages can wait for, such as the screen
  /// the user is on. Values are strings, numbers or booleans. Triggers stay
  /// on the phone and are forgotten when the app closes.
  static void addTrigger(String key, Object value) => _i.addTriggers({key: value});

  static void addTriggers(Map<String, Object> triggers) => _i.addTriggers(triggers);

  static void removeTrigger(String key) => _i.removeTriggers([key]);

  static void removeTriggers(List<String> keys) => _i.removeTriggers(keys);

  static void clearTriggers() => _i.clearTriggers();

  /// Stops (true) or allows (false) in-app messages, for example during a
  /// call. A message on screen is hidden. For one screen, wrap it in
  /// [DakInAppBlock] instead.
  static void pauseInApp(bool paused) => _i.setPaused(paused);

  static bool get isInAppPaused => _i.isPaused;

  /// Taps on in-app messages and their buttons. Deep links are yours to
  /// route; `url` actions are opened in the browser and tag actions applied
  /// by the SDK already.
  static Stream<DakInAppClick> get onInAppClick => _i.onClick;

  /// The controller behind the in-app calls, or null before [init].
  static DakInAppController? get inAppController => _inApp;
}

class _Lifecycle with WidgetsBindingObserver {
  _Lifecycle(this.client, this.inApp);
  final DakClient client;
  final DakInAppController inApp;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(client.onResume());
    inApp.lifecycle(state);
  }

  /// Registered before the app's navigator, so the back button closes an
  /// in-app message instead of the page under it.
  @override
  Future<bool> didPopRoute() async => inApp.handleBack();
}
