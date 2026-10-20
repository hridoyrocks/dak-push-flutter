# dak_push example

A one-screen app to try the SDK against a running Dak server.

The repository keeps only `lib/` and `pubspec.yaml`. Generate the platform
folders and Firebase config once:

```bash
cd sdk/flutter/dak_push/example
flutter create . --platforms android,ios --org com.example.dak
flutterfire configure   # pick the Firebase project whose service account the Dak app uses
```

Then run it with your App ID and server URL:

```bash
flutter run --dart-define=DAK_APP_ID=<app id> --dart-define=DAK_URL=https://push.example.com
```

For a server on your Mac and the Android emulator, use `http://10.0.2.2:8080`
(and allow cleartext traffic for debug builds), or run the server behind HTTPS.

Send a test push from the server:

```bash
dak send <app id> --all --title "Hello" --body "From Dak" --url "example://home" --wait
```
