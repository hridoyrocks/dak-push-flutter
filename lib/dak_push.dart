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
export 'src/background.dart' show dakBackgroundMessageHandler;
export 'src/client.dart' show DakException;
export 'src/dak.dart' show Dak, DakOptions;
export 'src/in_app/controller.dart' show DakInAppController;
export 'src/in_app/host.dart' show DakInAppBlock, DakInAppHost, DakImageLoader;
export 'src/in_app/model.dart'
    show
        DakInAppAction,
        DakInAppButton,
        DakInAppClick,
        DakInAppCondition,
        DakInAppContent,
        DakInAppFrequency,
        DakInAppLayout,
        DakInAppMessage;
export 'src/notification.dart' show DakButton, DakNotification;
