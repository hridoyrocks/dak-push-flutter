import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:meta/meta.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Facts about the install the server uses for targeting. Nothing that
/// identifies the person or the phone: no model, no IP, no location (the UTC
/// offset only if the app opts in).
@internal
abstract class DakPlatformInfo {
  /// "android" or "ios".
  String get platform;
  Future<String> appVersion();
  Future<String> osVersion();
  String language();

  /// The phone's UTC offset in minutes right now (+360 in Bangladesh). Sent
  /// only with DakOptions(shareTimezoneOffset: true).
  int utcOffsetMinutes();
}

class DefaultPlatformInfo implements DakPlatformInfo {
  @override
  String get platform {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    throw UnsupportedError('Dak supports Android and iOS');
  }

  @override
  Future<String> appVersion() async {
    final info = await PackageInfo.fromPlatform();
    return info.buildNumber.isEmpty ? info.version : '${info.version}+${info.buildNumber}';
  }

  @override
  Future<String> osVersion() async {
    final plugin = DeviceInfoPlugin();
    if (Platform.isAndroid) return (await plugin.androidInfo).version.release;
    if (Platform.isIOS) return (await plugin.iosInfo).systemVersion;
    return '';
  }

  @override
  String language() => PlatformDispatcher.instance.locale.languageCode.toLowerCase();

  @override
  int utcOffsetMinutes() => DateTime.now().timeZoneOffset.inMinutes;
}
