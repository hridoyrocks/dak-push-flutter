# dak_push example

A one-screen app to try the SDK against a running Dak server.

The Android and iOS projects are already set up for the SDK's minimums
(minSdk 23, and iOS 15 in `ios/Podfile` and the Runner target). Before the
first run:

1. Optionally change the Android application id
   (`com.example.dak.dak_push_example`) and the iOS bundle id
   (`com.example.dak.dakPushExample`) to your own.
2. Add the Firebase config. `flutterfire configure` registers the app ids in
   Firebase and writes `google-services.json` and `GoogleService-Info.plist`,
   which `Dak.init` reads:

   ```bash
   cd example
   flutterfire configure   # pick the Firebase project whose service account the Dak app uses
   ```

3. For pushes on iOS, open `ios/Runner.xcworkspace` in Xcode, pick your team,
   and add the Push Notifications and Background Modes (Remote notifications)
   capabilities, as the [README](../README.md#platform-setup) describes. If
   `pod install` fails, run `pod install --repo-update` in `ios/`.

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

Try the new message options:

```bash
curl https://push.example.com/v1/messages -H "Authorization: Bearer $DAK_REST_KEY" -H "Content-Type: application/json" -d '{
  "target": {"all": true},
  "title": "Hi {{name|friend}}", "body": "Tap a button",
  "translations": {"bn": {"title": "হ্যালো {{name|বন্ধু}}", "body": "একটা button চাপুন"}},
  "buttons": [{"id": "yes", "text": "Yes", "url": "example://yes"}, {"id": "no", "text": "No"}]
}'
```
