import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'client.dart';
import 'in_app/controller.dart';
import 'in_app/host.dart';
import 'in_app/model.dart';
import 'messaging.dart';
import 'notification.dart';
import 'platform_info.dart';
import 'storage.dart';

class DakOptions {
  const DakOptions({
    this.showInForegroundOnIOS = false,
    this.debugLogs = false,
    this.sessionTimeout = const Duration(minutes: 5),
  });

  /// iOS only: let the system show notifications while the app is open.
  /// (On Android an open app gets them through [Dak.onForeground].)
  final bool showInForegroundOnIOS;

  /// Print what the SDK does (debug builds only).
  final bool debugLogs;

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

  /// Starts the SDK: gets the FCM token and registers the device. Safe to
  /// call more than once. Initializes Firebase if the app has not. Call it
  /// before runApp, so the back button closes in-app messages first.
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
    final api = DakApi(baseUrl: baseUrl, appId: appId);
    final log = options.debugLogs && kDebugMode ? debugPrint : null;
    final client = DakClient(
      api: api,
      messaging: messaging,
      storage: SecureDakStorage(),
      platform: DefaultPlatformInfo(),
      log: log,
    );
    final inApp = DakInAppController(
      api: api,
      storage: SecureDakStorage(const FlutterSecureStorage(), 'dak_push_in_app'),
      credentials: () => client.credentials,
      setTags: client.setTags,
      openUrl: (url) => launchUrl(url, mode: LaunchMode.externalApplication),
      sessionTimeout: options.sessionTimeout,
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
