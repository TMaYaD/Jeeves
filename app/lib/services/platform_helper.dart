import 'package:flutter/services.dart' show SystemNavigator;

/// Stub for web — no Android detection available.
bool get isAndroidPlatform => false;

/// Close the app. Web stub: defers to [SystemNavigator.pop]; the browser
/// generally controls tab lifetime.
Future<void> closeApp() => SystemNavigator.pop();
