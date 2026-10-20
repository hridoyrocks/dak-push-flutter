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
