import 'dart:io' show Platform, exit;

import 'package:flutter/services.dart' show SystemNavigator;

/// Native platforms — delegate to dart:io.
bool get isAndroidPlatform => Platform.isAndroid;

/// Close the app. On Android, hard-exit so the cached FlutterEngine
/// doesn't reattach to a stale widget tree on relaunch.
Future<void> closeApp() async {
  if (Platform.isAndroid) {
    exit(0);
  }
  await SystemNavigator.pop();
}
