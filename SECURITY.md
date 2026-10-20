# Security policy

## Supported versions

dak_push is below 1.0, so only the newest release gets security fixes. Fixes
go into a new patch release; update to it.

| Version | Supported |
|---|---|
| Newest 0.x release | Yes |
| Older releases | No |

## Reporting a vulnerability

Please do not open a public issue, discussion or pull request for a security
problem.

Report it privately on GitHub: open the repository's **Security** tab and
choose **Report a vulnerability**
([direct link](https://github.com/hridoyrocks/dak-push-flutter/security/advisories/new)).
Only the maintainers can see the report.

Include what you can of:

- the affected version or commit, platform (Android, iOS, the notification
  service extension) and firebase_messaging version;
- what an attacker can do, and what they need first (another app on the
  phone, a network position, a stolen device, access to the Dak server);
- steps or a small app that shows the problem.

## What happens next

- We aim to confirm we received the report within 3 working days and to give
  a first assessment within 7.
- We fix confirmed problems in a new release and publish a GitHub security
  advisory with it. Unless you prefer otherwise, the advisory credits you.
- Please give us 90 days, or until the fix is released if that is sooner,
  before you disclose the problem publicly. If a problem is already being
  exploited, we will move faster and tell you.

## Scope

In scope: this repository, meaning the Dart library, the Android and iOS
plugin code, and `ios_extension/DakNotificationService.swift`.

Report problems in the Dak server the same way; we pass them on. Problems in
Firebase, flutter_secure_storage or other dependencies belong to their own
projects, but tell us if dak_push uses them in an unsafe way.

## How the SDK handles secrets

Useful context for a report:

- The device secret the server issues is kept in flutter_secure_storage
  (Android Keystore, iOS Keychain). It is sent only to the `baseUrl` you pass
  to `Dak.init`.
- The iOS notification service extension gets only a receipt token, the
  SHA-256 of the device secret, through the App Group. The receipt token can
  report deliveries and nothing else.
- The identity verification hash (`authHash`) is an HMAC your server computes.
  The identity secret must never be in the app.
