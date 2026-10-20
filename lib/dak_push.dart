/// Flutter SDK for Dak, a self-hosted push notification server.
///
/// ```dart
/// await Dak.init(appId: 'APP_ID', baseUrl: 'https://push.example.com');
/// await Dak.requestPermission();
/// await Dak.login(userId, authHash: hashFromYourServer);
/// Dak.onOpened.listen((n) => openRoute(n.url));
/// ```
library;

export 'src/api.dart' show DakApiException;
export 'src/background.dart' show dakBackgroundMessageHandler;
export 'src/client.dart' show DakClient, DakException, receiptToken;
export 'src/dak.dart' show Dak, DakOptions;
export 'src/messaging.dart' show DakMessaging, DakPushToken;
export 'src/native.dart' show DakNative, NoDakNative;
export 'src/notification.dart' show DakButton, DakNotification;
export 'src/platform_info.dart' show DakPlatformInfo;
export 'src/storage.dart' show DakStorage, MemoryDakStorage;
