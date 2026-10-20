# dak_push

Flutter SDK for Dak, a self-hosted push notification server. It registers the device with your Dak server, links
it to your user, keeps tags, reports deliveries, opens and button taps, and
shows in-app messages.

Android and iOS. Delivery goes through your own Firebase project (FCM, and
APNs via the key in Firebase), so pushes cost nothing. Works with
firebase_messaging 15, 16 and 17.

Moving from OneSignal? See [Migrating from OneSignal](doc/migrating-from-onesignal.md).

## Requirements

| | Minimum |
|---|---|
| Flutter | 3.22 (Dart 3.4) |
| Android | minSdk 23 (Android 6.0) |
| iOS | 15.0 |
| firebase_messaging | 15, 16 or 17 (with firebase_core 3, 4 or 5) |
| Server | A Dak server, and a Firebase project whose service account the Dak app uses |

iOS 15 is what Firebase's iOS SDK 12 (firebase_messaging 16 and 17) needs,
and flutter_secure_storage 10 needs Android 23. CI checks the oldest and
newest Flutter, each firebase_messaging major, and the lowest dependency
versions the pubspec allows.

## Install

Until the package is on pub.dev, add it from this repository:

```yaml
dependencies:
  dak_push:
    git:
      url: https://github.com/hridoyrocks/dak-push-flutter.git
```

`pubspec.lock` keeps the exact commit; `flutter pub upgrade dak_push` takes
the newest.

The app needs Firebase set up as usual (`flutterfire configure`, which writes
`google-services.json` and `GoogleService-Info.plist`), and the APNs key
uploaded in Firebase (Project settings → Cloud Messaging). Remove other push
SDKs (OneSignal) so only one library handles notifications.

## Platform setup

**Android:** raise the minimum SDK in `android/app/build.gradle.kts` (or
`build.gradle`) if it is below 23:

```kotlin
defaultConfig {
    minSdk = 23 // or flutter.minSdkVersion, which is 24 from Flutter 3.35
}
```

**iOS:**

1. Set the deployment target to 15.0: in `ios/Podfile`,

   ```ruby
   platform :ios, '15.0'
   ```

   and in Xcode, Runner target → General → Minimum Deployments → iOS 15.0.
   Then run `pod install` in `ios/` (or `flutter build ios`, which runs it).
2. In Xcode, Runner target → Signing & Capabilities → + Capability:
   - **Push Notifications.**
   - **Background Modes**, with **Remote notifications** ticked. Silent (data
     only) pushes need it: without it iOS does not wake the app for them.
     iOS also limits how often it wakes an app this way, so do not rely on
     silent pushes for anything that must arrive.
3. Optional: the [notification service extension](doc/ios-notification-service-extension.md)
   for delivered receipts, images, buttons and badge increments.

## Use

```dart
await Dak.init(
  appId: 'APP_ID',
  baseUrl: 'https://push.example.com',
  options: const DakOptions(
    shareTimezoneOffset: true,           // optional, see "Local time"
    iosAppGroup: 'group.com.example.app', // optional, see "iOS extension"
  ),
);

// Ask when it makes sense in your app (iOS, Android 13+).
await Dak.requestPermission();

// After your own login. authHash comes from your server (see below).
await Dak.login(user.id, authHash: user.pushAuthHash);
await Dak.logout();

await Dak.setTags({'name': 'Rahim', 'level': 'b2', 'premium': true});
await Dak.deleteTags(['level']);
await Dak.setSubscribed(false); // user turned pushes off in your settings

// Deep links. The SDK reports the open (and the tapped button) itself.
final launch = Dak.initialNotification; // tapped to start the app
Dak.onOpened.listen((n) {
  if (n.actionId == 'accept') acceptRequest(n.data['request_id']);
  router.go(n.url ?? '/'); // the button's own URL if it has one
});

// While the app is open, Android shows nothing by itself. Silent (data
// only) pushes arrive here too, with no title or body.
Dak.onForeground.listen((n) => n.isSilent ? sync(n.data) : showInAppBanner(n.title, n.body));

await Dak.setBadge(0); // iOS
```

`Dak.init` returns once the saved state and the tapped notification are read;
the push token and the registration follow in the background, so a bad network
never holds the splash screen. Calls made meanwhile (`login`, `setTags`) wait
for the saved state and then sync. Taps that come before you listen to
`onOpened` are kept for your first listener.

`login` and `setTags` throw `DakException` only for mistakes the app must fix
(wrong auth hash, bad tag). Only the refused field is rolled back: an opt-out
sent with a wrong auth hash still goes through. Network problems never throw:
changes are saved and sent later, also after an app restart. Refusals from
syncs nobody awaits (a retry, a token refresh) come on `Dak.onError`:

```dart
Dak.onError.listen((e) => log('dak refused ${e.field ?? e.code}: ${e.message}'));
```

## Delivered receipts

The "delivered" count on a message counts phones that reported the push
arrived:

- **Android:** `Dak.init` registers a `FirebaseMessaging.onBackgroundMessage`
  handler that reports pushes arriving in the background; the app reports the
  ones arriving while it is open. Firebase allows one background handler per
  app. If your app has its own, turn Dak's off and call Dak from yours:

  ```dart
  @pragma('vm:entry-point')
  Future<void> myBackgroundHandler(RemoteMessage message) async {
    await Dak.handleBackgroundMessage(message);
    // … your own work
  }

  FirebaseMessaging.onBackgroundMessage(myBackgroundHandler);
  await Dak.init(appId: …, baseUrl: …, options: const DakOptions(handleBackgroundMessages: false));
  ```

- **iOS:** iOS does not wake the app for visible pushes, so receipts come from
  a Notification Service Extension: see
  [iOS extension](doc/ios-notification-service-extension.md). Without it iOS
  pushes are still sent and opened; they are just not counted as delivered
  until opened.

Receipts that cannot be sent (no network) are kept and sent on the next start.

## Buttons

A message can have up to 3 buttons (`buttons` in the API). The tap opens the
app; `n.actionId` is the button's id and the server counts taps per button.

- **Android:** FCM's own notifications cannot have buttons, so Dak sends such
  messages as data and this SDK shows them (title, body, image, buttons,
  channel). Devices with an older SDK (0.1, or 0.2 with in-app messages only) get
  the same notification without buttons.
- **iOS:** the [notification service extension](doc/ios-notification-service-extension.md)
  adds the buttons. With firebase_messaging 17 the tapped button comes from
  Firebase. With 15 or 16 the SDK reads it from the notification response,
  which needs your `AppDelegate` to be the notification center's delegate
  (`UNUserNotificationCenter.current().delegate = self` in
  `didFinishLaunchingWithOptions`, before `super`).

A message that arrives while the app is open is not shown on Android (like
any FCM message); `Dak.showNotification(n)` shows it with its buttons if you
want that.

## Languages

The server picks a message's title and body by the device's language
(`translations` in the API), so nothing is needed in the app. The SDK sends the
phone's language code.

## Local time

With `DakOptions(shareTimezoneOffset: true)` the SDK sends the phone's UTC
offset in minutes (+360 in Bangladesh), and again when it changes. Only the
offset: no timezone name, city or location. The server uses it for messages
with `local_time` ("send at 09:00 for each user") and for quiet hours. Without
it the app's timezone (set on the server) is used.

## In-app messages

Messages shown inside the app while it is open: a centred modal, a top or
bottom banner, a full-screen page or a card that slides up. They are drawn with
plain Flutter widgets (no WebView) and take your theme's colours unless the
message sets its own. Create them in the Dak dashboard or with the server's
REST API (`POST /v1/in-app`); push permission is not needed to see them.

Give them a place above all your pages, in `MaterialApp`'s builder:

```dart
MaterialApp(builder: Dak.inAppBuilder, ...);

// With a builder of your own:
MaterialApp(builder: (context, child) => DakInAppHost(child: myBuilder(context, child)));
```

Call `Dak.init` before `runApp`, so the Android back button closes a message
instead of the page under it.

```dart
// Triggers: conditions a message can wait for. Kept in memory only, never sent.
Dak.addTrigger('screen', 'home');
Dak.addTriggers({'lessons_done': 3, 'premium': true});
Dak.removeTrigger('screen');

// Clicks on a message or its buttons. Deep links are yours to route; `url`
// actions open the browser and `tags` actions set tags by themselves.
Dak.onInAppClick.listen((click) {
  if (click.actionType == 'deep_link') router.go(click.url!);
  analytics.log('in_app_click', {'message': click.messageId, 'button': click.buttonId});
});

// Keep messages away from screens that must not be covered:
Dak.pauseInApp(true);   // ... and false when done
// or, for one screen, while it is in the widget tree:
DakInAppBlock(child: CallScreen());
```

How it works:

- At each session start the SDK fetches the messages this device may see (the
  server checks the audience, schedule and status) and keeps them, so they also
  show offline. A new session starts on a cold start or after 5 minutes in the
  background (`DakOptions(sessionTimeout: …)`).
- The SDK checks each message's triggers on the phone: session count, time in
  the session, time since install, and your custom triggers. No triggers means
  "when the app opens".
- One message at a time, highest priority first. Frequency (`once`,
  `every_session`, every N seconds, at most N times) is kept on the phone and
  on the server.
- Impressions, clicks (with the button id) and dismissals are sent in batches;
  the server counts each event once and shows the stats per message.
- An image is loaded before the message shows. If it fails, a message with text
  shows without it; an image-only message waits for the next session.
- Messages this SDK version cannot show (a newer layout, action or trigger) are
  skipped.

## Identity verification

So nobody can claim another user's id and receive their pushes, the server
checks `authHash = hex(HMAC-SHA256(key: identity secret, message: user id))`.
Get the secret with `dak app identity-secret <app id>` and compute the hash on
your server, for example in Laravel:

```php
'push_auth_hash' => hash_hmac('sha256', (string) $user->id, config('services.dak.identity_secret')),
```

## Notification channels (Android)

A message's `android_channel` must be a channel your app created; otherwise
Android uses Firebase's fallback channel (and the SDK, for messages it shows,
your default channel or a "Notifications" channel). Create channels at startup
(for example with `flutter_local_notifications`) and name the default one in
`AndroidManifest.xml`:

```xml
<meta-data
    android:name="com.google.firebase.messaging.default_notification_channel_id"
    android:value="general" />
```

The SDK also uses Firebase's `default_notification_icon` and
`default_notification_color` meta-data for the notifications it shows.

## Firebase Installation IDs

firebase_messaging 17 deprecates registration tokens in favour of Firebase
Installation IDs (`register()` / `onRegistered`). With 17 the SDK registers
and sends the FID (`token_type: "fid"`); with 15 and 16, which do not have
`register()`, it sends the token as before. `DakOptions(useFid: false)` keeps
tokens on 17 too.

## What is stored

The SDK sends: the push token or FID, platform, app/OS/SDK version, language,
whether notifications are allowed, the user id and tags you set, which pushes
arrived and were opened (with the button), which in-app messages were shown,
clicked or dismissed, and the UTC offset only if you turn it on. Nothing else:
no IP, location, phone number, email or device model. In-app triggers stay on
the phone.

## Troubleshooting

Turn on `DakOptions(debugLogs: true)` first: in debug builds the SDK prints
what it registers, sends and retries.

**`pod install` says a pod "required a higher minimum deployment target".**
Set `platform :ios, '15.0'` in `ios/Podfile` and the Runner target to iOS 15
(see [Platform setup](#platform-setup)), then run `pod install --repo-update`
in `ios/`.

**Android build: "minSdkVersion 21 cannot be smaller than version 23 declared in
library".** Set `minSdk = 23` or higher in `android/app/build.gradle.kts`.

**Swift Package Manager: "the package at '…/FlutterFramework' cannot be
accessed".** firebase_core 5 and firebase_messaging 17 need a Flutter that
generates the FlutterFramework package (3.35 does not; 3.47 does). Update
Flutter, or build with CocoaPods (`flutter config --no-enable-swift-package-manager`).

**The device never shows up on the server.**
- Check `appId` and `baseUrl` (the server's public URL, without `/v1`). Use
  `https`: plain `http` needs cleartext traffic allowed on Android and an App
  Transport Security exception on iOS.
- The Dak app needs the service account of the same Firebase project as the
  app's `google-services.json` / `GoogleService-Info.plist`.
- On iOS a push token exists only after APNs registration: use a real device,
  with the Push Notifications capability and the APNs key uploaded in Firebase.

**Pushes arrive on Android but not on iOS.** Usually APNs: upload the APNs
key in Firebase (Project settings → Cloud Messaging, under the iOS app with
the right bundle id), and check that the Runner target has the Push
Notifications capability in the build you run.

**Nothing appears while the app is open.** Expected on Android: FCM does not
show messages to an open app. Listen to `Dak.onForeground` and call
`Dak.showNotification(n)` if you want the system notification. On iOS pass
`DakOptions(showInForegroundOnIOS: true)`.

**`login` throws `DakException`.** The server rejected the request for good:
usually the `authHash` does not match (identity verification is on, and the
hash must be `hex(HMAC-SHA256(key: identity secret, message: user id))` over
the exact same user id string). `ArgumentError` means a bad user id or tag, before
anything was sent.

**The "delivered" count stays at 0 on iOS.** iOS does not run app code for
visible pushes; set up the [notification service extension](doc/ios-notification-service-extension.md)
with the same App Group in the app, the extension and `DakOptions(iosAppGroup:)`.

**Buttons do not appear on iOS.** They are added by the notification service
extension. Long-press the notification to see them.

**`actionId` is null for button taps on iOS with firebase_messaging 15 or 16.**
Make your `AppDelegate` the notification center's delegate (see
[Buttons](#buttons)).

**Android pushes that arrive in the background are not counted as delivered.**
Firebase keeps one `onBackgroundMessage` handler per app, and a handler your
app sets replaces Dak's. Pass `DakOptions(handleBackgroundMessages: false)`
and call `Dak.handleBackgroundMessage` from your handler (see
[Delivered receipts](#delivered-receipts)).

**In-app messages never show.** Check that `MaterialApp(builder: Dak.inAppBuilder)`
(or a `DakInAppHost`) is in place, that `Dak.pauseInApp(true)` is not left on,
that no `DakInAppBlock` covers the screen, and that the message's triggers can
be met. Messages are fetched at session start: restart the app, or come back
after the session timeout (5 minutes by default).

**Another push SDK is still installed.** Two libraries handling the same FCM
messages leads to duplicates and lost taps. Remove the other one; see
[Migrating from OneSignal](doc/migrating-from-onesignal.md).

## Security

Report security problems privately, as [SECURITY.md](SECURITY.md) describes,
not in a public issue.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
