/// Keeps a screen out of screenshots, the recents thumbnail and screen mirrors.
///
/// Any surface that shows a secret exactly once needs this. Today that is the
/// enrolment ceremony, whose recovery passphrase is the account's encryption
/// ceiling; the control is deliberately general, because a security measure that
/// belongs to one screen is one that quietly stops applying when the screen
/// changes.
///
/// Android's `FLAG_SECURE` is the whole mechanism: the window is excluded from
/// `screencap`, from non-secure displays, and — the one that matters for a
/// show-once recovery passphrase — from the **recents thumbnail**, which the
/// system captures without asking and keeps until the task is dismissed.
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

/// Handled by `MainActivity.kt`. Named here so a test can script it.
const MethodChannel secureScreenChannel = MethodChannel('jeeves/secure_screen');

/// Add (or clear) `FLAG_SECURE` on the app window.
///
/// Window-scoped rather than screen-scoped, because that is what the platform
/// offers: a caller that sets it on entry **must** clear it on exit, or every
/// later screen inherits a flag it never asked for.
///
/// No platform branch: every platform other than Android answers with
/// [MissingPluginException] because there is nothing to call, and that is the
/// honest signal — reported rather than silently absorbed, so a surface that
/// believes it is protected and is not shows up in the log.
Future<void> setSecureScreen({required bool secure}) async {
  try {
    await secureScreenChannel.invokeMethod<void>(
      'setSecure',
      <String, Object?>{'secure': secure},
    );
  } on MissingPluginException {
    debugPrint(
      'secure screen: FLAG_SECURE is unavailable on this platform, so a '
      'show-once secret on screen is capturable',
    );
  }
}
