/// The platform's device name, in a browser.
///
/// A browser keeps no name for the machine it runs on, so the only thing it
/// offers is the user agent — which says who it is pretending to be. That
/// makes a recognisable default ("Chrome on macOS") and nothing more.
library;

import 'package:web/web.dart' as web;

import 'user_agent_device_name.dart';

/// The name the browser's user agent gives this device, or `null` when it
/// says nothing we recognise.
Future<String?> readPlatformDeviceName() async {
  return deviceNameFromUserAgent(web.window.navigator.userAgent);
}
