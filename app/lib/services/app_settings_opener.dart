/// The port for opening the app's own settings page (issue #55).
///
/// The OS stops showing its location prompt after two refusals. When that
/// has happened, the only way left to let the user allow the location is the
/// app's settings page — so Jeeves opens it rather than asking again.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Where the app's own settings live.
abstract class AppSettingsOpener {
  /// Whether this device has a settings page Jeeves can open.
  bool get canOpenSettings;

  /// Opens the app's settings page. Returns whether it opened.
  Future<bool> openSettings();
}

/// The Android settings page, through a platform channel.
class MethodChannelAppSettingsOpener implements AppSettingsOpener {
  const MethodChannelAppSettingsOpener();

  static const MethodChannel _channel = MethodChannel('jeeves/app_settings');

  @override
  bool get canOpenSettings =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<bool> openSettings() async {
    if (!canOpenSettings) return false;
    try {
      final opened = await _channel.invokeMethod<bool>('openAppSettings');
      return opened ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

/// A device with no settings page to open.
class NoAppSettingsOpener implements AppSettingsOpener {
  const NoAppSettingsOpener();

  @override
  bool get canOpenSettings => false;

  @override
  Future<bool> openSettings() async => false;
}
