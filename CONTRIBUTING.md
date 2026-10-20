# Contributing to dak_push

Thanks for helping. Bug reports, docs fixes and pull requests are all welcome.
For a larger change, open an issue first so we can agree on the approach
before you spend time on it.

Security problems are the exception: report them privately, as
[SECURITY.md](SECURITY.md) describes.

## Set up

You need Flutter 3.22 or newer; CI's main jobs use the version in
`FLUTTER_VERSION` in [.github/workflows/ci.yml](.github/workflows/ci.yml).

```bash
flutter pub get
flutter test
```

The [example app](example/README.md) runs the SDK against a real Dak server.
To build it with Swift Package Manager, clone the repository into a folder
named `dak_push` (`git clone https://github.com/hridoyrocks/dak-push-flutter.git dak_push`):
Flutter names the example's path dependency after the folder, and Xcode
rejects a name that is not the plugin's. Apps that install dak_push from
git or pub.dev are not affected.
`flutterfire configure` changes tracked files in `example/` (Gradle settings,
the Xcode project); do not commit those changes or your Firebase config.

## Before you open a pull request

CI runs these, and a pull request needs them to pass:

```bash
dart format .
flutter analyze
flutter test --coverage
```

It also builds the example for Android and iOS, and runs the tests against
firebase_messaging 15, 16 and 17, the lowest dependency versions, and the
oldest and newest Flutter.

- Add tests for new behaviour and for the bug you fix. The fakes in
  `test/fakes.dart` stand in for Firebase, storage, the platform and the
  server.
- Document public API with `///` comments.
- Add a line to CHANGELOG.md under `## Unreleased`. Start it with
  **Breaking:** if apps must change code or settings to update.
- Native changes (Kotlin, Swift, the notification service extension) cannot be
  tested in CI beyond building: say in the pull request which devices and OS
  versions you tried them on.
- Keep each pull request to one change.

## Versions and releases

dak_push follows [semantic versioning](https://semver.org). Below 1.0, a
breaking change raises the minor version (0.3 → 0.4) and anything else the
patch version.

The version is written in four places, and a test checks that they match:

- `pubspec.yaml` (`version`)
- `lib/src/client.dart` (`kDakSdkVersion`, which the server sees)
- `ios/dak_push.podspec` (`s.version`)
- `android/build.gradle` (`version`)

To release (maintainers):

1. Raise the version in all four places, and turn `## Unreleased` in
   CHANGELOG.md into `## X.Y.Z - YYYY-MM-DD`.
2. Merge that to `main` and wait for CI to pass.
3. Tag the merge commit `vX.Y.Z` and push the tag.
4. Make a GitHub release from the tag, with the CHANGELOG section as notes.
5. Update the `ref:` in the README's install snippet and in the Dak
   dashboard's setup wizard.

Never move or delete a tag, and never rewrite `main`'s history: apps pin
dak_push by tag or commit through git, and a rewritten history breaks their
builds. Fix a bad release with a new one.

## Code of conduct

Everyone taking part is expected to follow the
[code of conduct](CODE_OF_CONDUCT.md).
