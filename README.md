# dak_push

Flutter SDK for Dak, a self-hosted push notification server. It registers the device with your Dak server, links
it to your user, keeps tags, reports deliveries, opens and button taps, and
shows in-app messages.

Android and iOS. Delivery goes through your own Firebase project (FCM, and
APNs via the key in Firebase), so pushes cost nothing. Works with
firebase_messaging 15, 16 and 17.

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

The app needs Firebase set up as usual (`google-services.json`,
`GoogleService-Info.plist`, Push Notifications capability on iOS). Remove
other push SDKs (OneSignal) so only one library handles notifications.

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
await Dak.logout(); // also removes this device's tags

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

`login` and `setTags` throw `DakException` only for mistakes the app must fix
(wrong auth hash, bad tag). Network problems never throw: changes are saved and
sent later, also after an app restart. When the server asks the SDK to slow
down (`Retry-After`), changes are only saved until then.

`baseUrl` must be `https` (plain `http` works only for `localhost` and the
Android emulator's `10.0.2.2`). Lengths are counted in UTF-8 bytes, as the
server does: a tag value is at most 255 bytes (85 Bangla letters), a user id
128.

On iOS the keychain keeps the SDK's state after the app is deleted. The SDK
marks each install with a file that is deleted with the app, so after a
reinstall it starts over as a new device instead of bringing back the old
user and tags.

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
  `didFinishLaunchingWithOptions`, before `super`). Debug builds log a warning
  when a tap never reached the plugin.

A message that arrives while the app is open is not shown on Android (like
any FCM message); `await Dak.showNotification(n)` shows it the way it would
have looked in the background, buttons and image included. It returns false
when nothing was shown (on iOS, with notifications turned off, or without a
title and body).

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
- Without a successful fetch for a week, the cached list is not shown: the
  server may have stopped those messages since.
- A message that `pauseInApp` or a `DakInAppBlock` hides before the user closed
  it comes back afterwards, also for `once` messages; it counts as one
  impression.
- `url` actions open only `https` and `http` links
  (`DakOptions(inAppUrlSchemes: …)` to allow more, such as `mailto`); the click
  still reaches `onInAppClick`.
- Modal, card and full-screen messages take the keyboard focus like a dialog
  (Escape closes them) and give it back. Screen readers announce them as
  dialogs and banners as they appear; banners do not close by themselves for
  screen reader users. Layouts follow right-to-left languages.
- The host can be built before `Dak.init` finishes. With two hosts in the tree
  the outer one draws the messages.

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
