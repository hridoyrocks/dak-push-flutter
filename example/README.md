# dak_push example

A one-screen app to try the SDK against a running Dak server.

The repository keeps only `lib/` and `pubspec.yaml`. Generate the platform
folders and Firebase config once:

```bash
cd example
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

Try the new message options:

```bash
curl https://push.example.com/v1/messages -H "Authorization: Bearer $DAK_REST_KEY" -H "Content-Type: application/json" -d '{
  "target": {"all": true},
  "title": "Hi {{name|friend}}", "body": "Tap a button",
  "translations": {"bn": {"title": "হ্যালো {{name|বন্ধু}}", "body": "একটা button চাপুন"}},
  "buttons": [{"id": "yes", "text": "Yes", "url": "example://yes"}, {"id": "no", "text": "No"}]
}'
```
