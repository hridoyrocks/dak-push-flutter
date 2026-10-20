# Migrating from OneSignal

This guide moves a Flutter app from `onesignal_flutter` (5.x) to `dak_push`.
The concepts map closely: an app id, an external user id, tags, a click
listener, in-app triggers. What changes is where pushes go through: Dak sends
them with your own Firebase project, on Android and iOS.

## Before you start

- **A Dak server** with an app for this Flutter app, and its App ID.
- **Firebase on both platforms.** OneSignal talks to APNs itself, so many apps
  have Firebase only on Android, or not at all. Dak needs `firebase_core` and
  `firebase_messaging` in the app (`flutterfire configure`) and the APNs key
  uploaded in Firebase (Project settings → Cloud Messaging). The Dak app needs
  the service account of that Firebase project.
- **The minimums** in the [README](../README.md#requirements): iOS 15 and
  Android minSdk 23.

## Plan the switch

Subscribers do not move from OneSignal to Dak. A phone appears in Dak when it
first runs an app version with `dak_push`, so for a while some users are on
the old version:

1. Release the version with Dak. It registers each phone, logs the user in and
   sets tags as it starts.
2. During the overlap, send each message from Dak, and from OneSignal only to
   phones still on an old version (a OneSignal segment with an App Version
   filter). An updated iPhone keeps its APNs token, so a visible push that
   OneSignal sends to it is still shown, next to Dak's.
3. When most users have updated (a force update helps), stop sending from
   OneSignal.

Tags are not copied either. Set them from the app after login, from the data
you already have, the same way you set them for OneSignal.

## Replace the code

Remove `onesignal_flutter` from `pubspec.yaml` and add `dak_push` (see
[Install](../README.md#install)). Then:

| OneSignal | Dak |
|---|---|
| `OneSignal.initialize(appId)` | `await Dak.init(appId: appId, baseUrl: 'https://push.example.com')` |
| `OneSignal.Notifications.requestPermission(true)` | `await Dak.requestPermission()` |
| `OneSignal.login(userId)` | `await Dak.login(userId, authHash: hashFromYourServer)` |
| `OneSignal.logout()` | `await Dak.logout()` |
| `OneSignal.User.addTags({...})`, `addTagWithKey` | `await Dak.setTags({...})` (strings, numbers, booleans) |
| `OneSignal.User.removeTags([...])`, `removeTag` | `await Dak.deleteTags([...])` |
| `OneSignal.User.pushSubscription.optOut()` / `optIn()` | `await Dak.setSubscribed(false)` / `true` |
| `OneSignal.Notifications.addClickListener` | `Dak.onOpened.listen(...)`, plus `Dak.initialNotification` for the tap that launched the app |
| `event.result.actionId` (button) | `notification.actionId` |
| `event.notification.additionalData` | `notification.data` |
| `event.notification.launchUrl` | `notification.url` |
| `OneSignal.Notifications.addForegroundWillDisplayListener` | `Dak.onForeground.listen(...)`; on Android call `Dak.showNotification(n)` to show it, on iOS use `DakOptions(showInForegroundOnIOS: true)` |
| `OneSignal.InAppMessages.addTrigger(s)`, `removeTrigger(s)`, `clearTriggers` | `Dak.addTrigger(s)`, `Dak.removeTrigger(s)`, `Dak.clearTriggers` |
| `OneSignal.InAppMessages.paused(true)` | `Dak.pauseInApp(true)` |
| `OneSignal.InAppMessages.addClickListener` | `Dak.onInAppClick.listen(...)` |
| `OneSignal.Debug.setLogLevel(OSLogLevel.verbose)` | `DakOptions(debugLogs: true)` |

Two things work differently:

- **Identity verification.** Dak checks an HMAC of the user id that your
  server makes with the app's identity secret (see
  [Identity verification](../README.md#identity-verification)). Add the hash
  to your login response and pass it to `Dak.login`.
- **In-app messages need a host.** Add `builder: Dak.inAppBuilder` to your
  `MaterialApp` (or wrap your own builder in `DakInAppHost`). OneSignal drew
  them in a native window; Dak draws them with Flutter widgets.

## Remove OneSignal's native parts

**iOS:**

1. In `ios/Podfile`, delete the `target 'OneSignalNotificationServiceExtension'`
   block, then run `pod install`.
2. In Xcode, delete the `OneSignalNotificationServiceExtension` target and its
   folder, and remove it from Runner's **Embed Foundation Extensions** build
   phase.
3. To keep delivered receipts, images and buttons, add Dak's
   [notification service extension](ios-notification-service-extension.md)
   instead. You can reuse the App Group OneSignal used, or make a new one.
4. Keep the Push Notifications capability and Background Modes → Remote
   notifications.

**Android:** removing the package removes OneSignal's code and its manifest
entries. If you added OneSignal meta-data or a notification icon for it in
`AndroidManifest.xml`, remove it, and name your default channel and icon with
Firebase's meta-data instead (see
[Notification channels](../README.md#notification-channels-android)).

## Check it

- Run the app, and confirm the device appears on the Dak server with the user
  id and tags you set.
- Send a push to that user from the dashboard. Tap it, and check that
  `onOpened` routes to the right screen, from the background and from a cold
  start (`initialNotification`).
- Search the project for `OneSignal` and `onesignal`: nothing should be left.
