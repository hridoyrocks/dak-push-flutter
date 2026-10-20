import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Facts about the install the server uses for targeting. Nothing that
/// identifies the person or the phone: no model, no IP, no location.
abstract class DakPlatformInfo {
  /// "android" or "ios".
  String get platform;
  Future<String> appVersion();
  Future<String> osVersion();
  String language();
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
}
