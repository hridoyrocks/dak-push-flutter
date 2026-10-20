# Changelog

All notable changes to dak_push. Versions follow [semantic versioning](https://semver.org);
below 1.0 a breaking change raises the minor version. **Breaking** marks
changes that need code or settings changes in apps.

## Unreleased

- **Breaking:** the minimums are now iOS 15 (podspec and Package.swift) and
  Android minSdk 23. firebase_messaging 16+ (Firebase iOS SDK 12) and
  flutter_secure_storage 10 already needed them; apps below must raise their
  deployment target and `minSdk`. See the README's Requirements.
- The example app has its Android and iOS projects.

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
