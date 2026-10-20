## 0.3.1 (2026-10-21)

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

## 0.3.0

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
- `DakMessaging` now returns `DakPushToken` (value and type), and
  `DakPlatformInfo` has `utcOffsetMinutes()`; `DakStorage` keeps receipts.
- The SDK version reported to the server is 0.3.0: the server shows Android
  buttons only from this version on.

## 0.2.0

- In-app messages: modal, top/bottom banner, full-screen and card layouts in
  plain Flutter widgets; buttons with deep link, URL, tag, dismiss and custom
  actions; triggers checked on the phone (session count, session time, time
  since install, `Dak.addTrigger`); frequency and priority; works offline from
  a cached list; impressions, clicks and dismissals reported in batches.
- New: `Dak.inAppBuilder`, `DakInAppHost`, `DakInAppBlock`, `Dak.addTrigger(s)`,
  `Dak.removeTrigger(s)`, `Dak.clearTriggers`, `Dak.pauseInApp`,
  `Dak.onInAppClick`, `DakOptions.sessionTimeout`.
- New dependency: url_launcher 6 (opens `url` actions).

## 0.1.0

- First version: registration, login/logout with identity hash, tags,
  subscribe/unsubscribe, permission prompt, open tracking, foreground stream,
  offline retry with saved state.
- Works with firebase_messaging 15–17 and firebase_core 3–5.
