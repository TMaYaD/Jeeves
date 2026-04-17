import 'dart:io' show Platform;

/// Native platforms — delegate to dart:io.
bool get isAndroidPlatform => Platform.isAndroid;
