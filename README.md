# dak_push

Flutter SDK for [Dak](../../../README.md), a self-hosted push notification
server. It registers the device's FCM token with your Dak server, links it to
your user, keeps tags, and reports when a notification is opened.

Android and iOS. Delivery goes through your own Firebase project (FCM, and
APNs via the key in Firebase), so pushes cost nothing.

## Install

```yaml
dependencies:
  dak_push:
    git:
      url: https://github.com/hridoyrocks/dak-push.git
      path: sdk/flutter/dak_push
```

The app needs Firebase set up as usual (`google-services.json`,
`GoogleService-Info.plist`, Push Notifications capability on iOS). Remove
other push SDKs (OneSignal) so only one library handles notifications.

## Use

```dart
await Dak.init(appId: 'APP_ID', baseUrl: 'https://push.example.com');

// Ask when it makes sense in your app (iOS, Android 13+).
await Dak.requestPermission();

// After your own login. authHash comes from your server (see below).
await Dak.login(user.id, authHash: user.pushAuthHash);
await Dak.logout();

await Dak.setTags({'level': 'b2', 'premium': true});
await Dak.deleteTags(['level']);
await Dak.setSubscribed(false); // user turned pushes off in your settings

// Deep links. The SDK reports the open to the server by itself.
final launch = Dak.initialNotification; // tapped to start the app
Dak.onOpened.listen((n) => router.go(n.url ?? '/'));

// While the app is open, Android shows nothing by itself.
Dak.onForeground.listen((n) => showInAppBanner(n.title, n.body));
```

`login` and `setTags` throw `DakException` only for mistakes the app must fix
(wrong auth hash, bad tag). Network problems never throw: changes are saved and
sent later, also after an app restart.

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
Android uses Firebase's fallback channel. Create channels at startup (for
example with `flutter_local_notifications`) and name the default one in
`AndroidManifest.xml`:

```xml
<meta-data
    android:name="com.google.firebase.messaging.default_notification_channel_id"
    android:value="general" />
```

## What is stored

The SDK sends: the FCM token, platform, app/OS/SDK version, language, whether
notifications are allowed, the user id and tags you set. Nothing else: no IP,
location, phone number, email or device model.

## Firebase Installation IDs

firebase_messaging 17 deprecates registration tokens in favour of Firebase
Installation IDs (`register()` / `onRegistered`). This version still uses tokens
so it works with firebase_messaging 15–17; the server already accepts FIDs
(`token_type: "fid"`), so a later SDK version can switch without server changes.
