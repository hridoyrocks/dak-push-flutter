# Changelog

All notable changes to dak_push. Versions follow [semantic versioning](https://semver.org);
below 1.0 a breaking change raises the minor version. **Breaking** marks
changes that need code or settings changes in apps.

## 0.4.0 - 2026-10-21

Correctness and robustness fixes from a review of the SDK.

**Breaking**

- The minimums are now iOS 15 (podspec and Package.swift) and Android
  minSdk 23. firebase_messaging 16+ (Firebase iOS SDK 12) and
  flutter_secure_storage 10 already needed them; apps below must raise their
  deployment target and `minSdk`. See the README's Requirements.
- `Dak.logout()` also removes the device's tags, so the next user of the phone
  does not get them.
- `baseUrl` must be `https`; plain `http` only for `localhost`, `127.0.0.1`,
  `::1` and the Android emulator's `10.0.2.2`.
- `Dak.showNotification` returns `Future<bool>` (false when nothing was shown)
  and now shows any message, not only those with buttons.
- In-app messages: one that `pauseInApp` or `DakInAppBlock` hides before the
  user closed it comes back afterwards, also when its frequency is `once`.
- The SDK's internals are no longer exported from
  `package:dak_push/dak_push.dart`: `DakClient`, `DakMessaging`,
  `DakPushToken`, `DakNative`, `NoDakNative`, `DakPlatformInfo`, `DakStorage`,
  `MemoryDakStorage` and `receiptToken`. Apps use `Dak`; these served the
  SDK's own tests, and their interfaces changed in this release too.

**Client**

- Registration sends the whole state, `external_id` and `utc_offset_minutes`
  as null when unset, so a server row taken over for the token keeps nothing of
  an earlier install. Newer Dak servers also replace the tags at
  registration.
- iOS keeps the keychain after an uninstall: a marker file in the SDK's own
  folder (deleted with the app, not backed up) tells such state apart, and it
  is dropped instead of bringing back the old user and tags.
- Lengths are checked in UTF-8 bytes, as the server counts them (tag values
  255, user ids 128); app and OS versions are cut to 32 bytes.
- A 401 on an open or a delivery receipt registers the device again (once per
  sync) instead of dropping it.
- Retries honour the server's `Retry-After` (changes are only saved meanwhile)
  and wait a random half of each step, so phones do not retry together.
  `DakApiException.retryAfter` has it.
- Overlapping `Dak.init` calls share one run; a failed run can be retried.
- Errors stay inside the SDK: failed saves, plugin calls that throw, errors on
  Firebase's streams. No retry runs after `dispose`.
- Receipts from the background handler are kept one key each and deleted only
  after the app saved them, so one arriving meanwhile is not lost.

**Android**

- A tap reaches the app also when another of its activities is on top
  (`FLAG_ACTIVITY_CLEAR_TOP`).
- Sound, light and vibration below Android 8 (`setDefaults`).
- The small icon is never an adaptive icon (Android 8.0 crashes the system UI
  on one): the manifest's icon, the app icon, or the system's, as FCM checks.
- A launch tap is no longer lost with a cached Flutter engine, or when an
  activity starts again while the engine lives on.

**iOS**

- Receipts the notification service extension cannot send are kept in the App
  Group; the app sends them on its next start or resume.
- Button categories: registered one push at a time and shown only once iOS has
  them; the 30 most recently used are kept (not random ones); the app puts them
  back when another plugin (flutter_local_notifications) replaced them all.
- A missing App Group is an error from the plugin (shown in debug builds, the
  sync goes on), and the extension logs setup problems to Console.app.
- Debug builds warn when the app delegate does not pass notification responses
  on (firebase_messaging 15 and 16), and when the copied extension is older than
  the plugin (new `schemaVersion`). Copy `DakNotificationService.swift` again.
- The privacy manifest declares the data sent to the app's Dak server (device
  id, user id, product interaction); `ios_extension/PrivacyInfo.xcprivacy` is
  the extension target's own manifest (ITMS-91053).

**In-app messages**

- Text, close and button colours stay readable on a background the message
  sets.
- A host or block built before `Dak.init` binds when the controller comes;
  hosts are counted, and only the first draws.
- Modal layouts take the keyboard focus and give it back; Escape closes them;
  messages sit above the keyboard.
- Accessibility: a labelled close button, dialog semantics, live banners, no
  auto-dismiss for screen reader users, reduced motion, right-to-left layouts.
- Android predictive back: while a message shows, the app says it handles back,
  so the gesture closes the message instead of the app.
- The cached list is not shown after a week without a successful fetch.
- Images are decoded at the size they are drawn.
- `url` actions open only `https` and `http` links
  (`DakOptions.inAppUrlSchemes`).
- The cache is a plain file in the SDK's folder instead of secure storage
  (moved once).
- No more CurvedAnimation per build.

**Project**

- The example app has its Android and iOS projects.
- README: Requirements, platform setup and troubleshooting; a guide for
  [migrating from OneSignal](doc/migrating-from-onesignal.md); SECURITY.md and
  CONTRIBUTING.md.
- API docs for every public member. `DakInAppCondition` and
  `DakInAppFrequency` are exported: they are the types of
  `DakInAppMessage.triggers` and `frequency`.

## 0.3.1 - 2026-10-21

Security and data-loss fixes. No API is removed; update and rebuild.

- **Android, security:** a tap is accepted only from a notification the SDK
  posted. Each one carries a random nonce kept in app-private storage, used
  once. Before, any app could start the launcher activity with Dak's extras
  and fake a tap (a deep link in `onOpened`, an open report, cancelling a
  notification), and the system replayed a tap after a low-memory kill.
  Notifications posted by 0.3.0 and still in the tray open the app without
  the tap.
- **iOS, data loss:** the keychain items are now readable after the first
  unlock (`first_unlock_this_device`). A push or background fetch that
  launched the app on a locked iPhone could not read the state, and the next
  save replaced it (device id and secret lost). Items saved by 0.3.0 are moved
  over on first read. A state that cannot be read is retried (on resume and on
  a timer) and never saved over; the in-app cache works the same way.
- **Refused changes:** only the field the server names is rolled back
  (`external_id` or `tags`), never `subscribed`. Before, one wrong auth hash
  rolled back everything pending, a user's opt-out included. Only Dak's own
  JSON errors count: an HTML 403 or 401 from a proxy is retried, and no longer
  drops the device's credentials. New: `Dak.onError` (and `DakClient.onError`)
  with the refusals of syncs nobody awaited; `DakException.code` and `field`.
- **Startup:** `Dak.init` returns once the saved state and the tapped
  notification are read, without waiting for the push token (up to 15 s) or
  the network. Calls made meanwhile wait for the saved state, so it can no
  longer overwrite a `login` or `setTags`. Taps that come before the app
  listens to `onOpened` are kept (20 at most) for its first listener.
  `DakClient.start()` returns early the same way; `DakClient.firstSync`
  completes after the first sync.
- **Timeouts:** the request timeout now covers reading the answer too; a server
  that sent headers and stalled could hold every later sync. A failing
  firebase_messaging 17 `register()` no longer leaves an uncaught
  `TimeoutException` in the app's zone.
- **Images:** Android downloads have an 8 s deadline and a Content-Length
  check, and an out-of-memory decode posts the notification without the
  picture instead of crashing. The iOS extension downloads with its own
  session (15 s, 10 MB, 2xx and image types only) and deletes files it does
  not attach. Replace your copy of `ios_extension/DakNotificationService.swift`.
- **In-app:** sessions and impressions count only in the foreground, and an
  impression only after a frame shows the message (a `once` message was used
  up by a background launch). A message with a field of the wrong type is
  skipped alone, also from the cache. A fullscreen message with no close
  button, no buttons and no click action now shows the X (the server rejects
  that combination too).

## 0.3.0 - 2026-10-20

- Delivered receipts: a background message handler on Android (or
  `Dak.handleBackgroundMessage` from your own), the foreground stream, and a
  Notification Service Extension for iOS (`ios_extension/`), which also adds
  images, buttons and badge increments.
- Buttons: Android notifications with buttons are shown by the SDK (now a
  plugin with Android and iOS code); taps are reported with the button id
  (`DakNotification.actionId`, `buttons`); a button's own URL becomes `url`.
- Firebase Installation IDs with firebase_messaging 17 (`register()` /
  `onRegistered`, `token_type: "fid"`); tokens on 15 and 16.
- Opt-in UTC offset for local-time delivery (`shareTimezoneOffset`).
- `Dak.setBadge`, `Dak.clearBadge`, `Dak.showNotification`, silent pushes in
  `onForeground` (`isSilent`).
- **Breaking** for apps with their own `DakMessaging`, `DakPlatformInfo` or
  `DakStorage`: `DakMessaging` now returns `DakPushToken` (value and type),
  `DakPlatformInfo` has `utcOffsetMinutes()`, and `DakStorage` keeps receipts.
- The SDK version reported to the server is 0.3.0: the server shows Android
  buttons only from this version on.

## 0.2.0 - 2026-10-20

- In-app messages: modal, top/bottom banner, full-screen and card layouts in
  plain Flutter widgets; buttons with deep link, URL, tag, dismiss and custom
  actions; triggers checked on the phone (session count, session time, time
  since install, `Dak.addTrigger`); frequency and priority; works offline from
  a cached list; impressions, clicks and dismissals reported in batches.
- New: `Dak.inAppBuilder`, `DakInAppHost`, `DakInAppBlock`, `Dak.addTrigger(s)`,
  `Dak.removeTrigger(s)`, `Dak.clearTriggers`, `Dak.pauseInApp`,
  `Dak.onInAppClick`, `DakOptions.sessionTimeout`.
- New dependency: url_launcher 6 (opens `url` actions).

## 0.1.0 - 2026-10-20

- First version: registration, login/logout with identity hash, tags,
  subscribe/unsubscribe, permission prompt, open tracking, foreground stream,
  offline retry with saved state.
- Works with firebase_messaging 15–17 and firebase_core 3–5.
