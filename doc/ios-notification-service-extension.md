# iOS notification service extension

iOS shows a visible push without waking your app, so the app cannot report
that it arrived. A Notification Service Extension can: iOS runs it for each
push (with `mutable-content`, which Dak always sets) before showing it.

`ios_extension/DakNotificationService.swift` in this package is a complete
extension. It:

- reports the delivery to your Dak server (the message's "delivered" count and
  `delivered` webhooks),
- downloads the push's image and attaches it,
- adds the push's buttons, as a notification category it makes for them,
- adds `badge_increment` pushes to the badge.

It needs no pods and no Firebase code. It reads what it needs from an App
Group the app shares with it: the server URL, App ID, device id and a
*receipt token* (the SHA-256 of the device secret, which can report deliveries
and nothing else). The device secret stays in the app's keychain.

## Setup (once per app)

1. **App Group.** In Xcode, select the Runner target → Signing & Capabilities →
   \+ Capability → App Groups → add one, for example
   `group.com.example.app.dak`.

2. **Extension target.** File → New → Target → Notification Service
   Extension. Name it `DakNotificationService`, language Swift. When Xcode
   asks to activate the scheme, say Cancel (you build with Runner).
   - Set its deployment target to the app's (Runner's) or lower.
   - Give it the same App Group (Signing & Capabilities → App Groups).
   - Its bundle id must start with the app's, like
     `com.example.app.DakNotificationService`, and it needs its own
     provisioning profile (Xcode's automatic signing makes one).

3. **Code.** Copy `DakNotificationService.swift` from this package
   (`~/.pub-cache/hosted/pub.dev/dak_push-<version>/ios_extension/`, or the
   repository) into the extension's folder and add it to the extension
   target only. Replace the generated `NotificationService.swift` with:

   ```swift
   class NotificationService: DakNotificationService {}
   ```

   (Or delete it and set `NSExtensionPrincipalClass` in the extension's
   Info.plist to `$(PRODUCT_MODULE_NAME).DakNotificationService`.)

4. **Info.plist of the extension.** Add the App Group:

   ```xml
   <key>DakAppGroup</key>
   <string>group.com.example.app.dak</string>
   ```

5. **Flutter.** Pass the same group to the SDK:

   ```dart
   await Dak.init(
     appId: 'APP_ID',
     baseUrl: 'https://push.example.com',
     options: const DakOptions(iosAppGroup: 'group.com.example.app.dak'),
   );
   ```

6. **Podfile** (only if `pod install` complains about the new target): the
   extension uses no pods, so it needs no `target` block.

7. If your Podfile or build phases embed frameworks into every target, make
   sure the extension's *Embed* phase is not ordered after "Thin Binary"; a
   "Cycle inside Runner" build error means moving **Embed Foundation
   Extensions** above **Run Script** in Runner's Build Phases.

## Check it

- Send a push to one iPhone. In Dak, `GET /v1/messages/{id}` should show
  `"delivered": 1` within a few seconds, before you open it.
- A push with `"image"` shows the picture; one with `"buttons"` shows them
  when you long-press the notification.
- In Xcode → Debug → Attach to Process → `DakNotificationService` you can
  debug the extension while sending a push.

## Notes

- The extension has about 30 seconds per push. It reports the delivery and
  downloads the image at the same time; if time runs out, iOS shows the push
  as it came.
- Buttons are made as categories named `dak_…`. The extension keeps the app's
  own categories and at most 30 of Dak's.
- Images must be `https`, and a type iOS can attach (JPEG, PNG, GIF), at most
  10 MB.
- `Dak.setBadge(n)` and `Dak.clearBadge()` set the badge and the count the
  extension adds increments to. If the badge is changed elsewhere (another
  library), set it through Dak too, or increments start from Dak's count.
