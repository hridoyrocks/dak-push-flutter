## 0.2.0

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

## 0.1.0

- First version: registration, login/logout with identity hash, tags,
  subscribe/unsubscribe, permission prompt, open tracking, foreground stream,
  offline retry with saved state.
- Works with firebase_messaging 15–17 and firebase_core 3–5.
