/// The platform's device name, on a platform that has one to ask.
///
/// Android is the only platform here that keeps a name for the hardware. The
/// read goes through a method channel, because the setting lives in the
/// Android framework and not in Dart.
library;

import 'package:flutter/services.dart';

/// Handled by `MainActivity.kt`. Named here so a test can script it.
const MethodChannel deviceNameChannel = MethodChannel('jeeves/device_name');

/// The name the platform gives this device, or `null` when it gives none.
///
/// A name is a convenience, not a fact the app depends on: a device that
/// cannot be named still works, it is simply unnamed until the user names it.
/// So every way of not getting one — no plugin, a platform error, a blank
/// answer — is `null` rather than an exception. The caller phrases the
/// missing name itself.
Future<String?> readPlatformDeviceName() async {
  try {
    final String? name =
        await deviceNameChannel.invokeMethod<String>('getDeviceName');
    final String? trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed;
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}
