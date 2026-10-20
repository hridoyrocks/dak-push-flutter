/// Flutter SDK for Dak, a self-hosted push notification server.
///
/// ```dart
/// await Dak.init(appId: 'APP_ID', baseUrl: 'https://push.example.com');
/// await Dak.requestPermission();
/// await Dak.login(userId, authHash: hashFromYourServer);
/// Dak.onOpened.listen((n) => openRoute(n.url));
///
/// // In-app messages
/// MaterialApp(builder: Dak.inAppBuilder, ...);
/// Dak.addTrigger('screen', 'home');
/// Dak.onInAppClick.listen((c) => openRoute(c.url));
/// ```
library;

export 'src/api.dart' show DakApiException;
export 'src/client.dart' show DakClient, DakException;
export 'src/dak.dart' show Dak, DakOptions;
export 'src/in_app/controller.dart' show DakInAppController;
export 'src/in_app/host.dart' show DakInAppBlock, DakInAppHost, DakImageLoader;
export 'src/in_app/model.dart'
    show DakInAppAction, DakInAppButton, DakInAppClick, DakInAppContent, DakInAppLayout, DakInAppMessage;
export 'src/messaging.dart' show DakMessaging;
export 'src/notification.dart' show DakNotification;
export 'src/platform_info.dart' show DakPlatformInfo;
export 'src/storage.dart' show DakStorage, MemoryDakStorage;
