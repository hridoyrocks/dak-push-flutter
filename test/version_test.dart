import 'dart:io';

import 'package:dak_push/src/client.dart' show kDakSdkVersion;
import 'package:flutter_test/flutter_test.dart';

// The version is written in four places, and the CHANGELOG has a section for
// it. A release changes them together (see CONTRIBUTING.md).
void main() {
  String read(String path, RegExp pattern) {
    final match = pattern.firstMatch(File(path).readAsStringSync());
    if (match == null) throw StateError('no version found in $path');
    return match.group(1)!;
  }

  late String version;
  setUpAll(() => version = read('pubspec.yaml', RegExp(r'^version: (\S+)$', multiLine: true)));

  test('the Dart code, the podspec and build.gradle have the pubspec version', () {
    expect(kDakSdkVersion, version, reason: 'kDakSdkVersion in lib/src/client.dart');
    expect(read('ios/dak_push.podspec', RegExp(r"s\.version\s*=\s*'([^']+)'")), version,
        reason: 'ios/dak_push.podspec');
    expect(read('android/build.gradle', RegExp(r'^version = "([^"]+)"$', multiLine: true)), version,
        reason: 'android/build.gradle');
  });

  test('the CHANGELOG has a dated section for the version', () {
    final changelog = File('CHANGELOG.md').readAsStringSync();
    expect(changelog, contains(RegExp('^## ${RegExp.escape(version)} - \\d{4}-\\d{2}-\\d{2}\$', multiLine: true)));
  });
}
