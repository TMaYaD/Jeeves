/// The platform's device name.
///
/// Import this file wherever a default name is needed. The Dart compiler picks
/// the implementation at build time, the same rule `lib/sync/sync_store.dart`
/// follows (docs/ARCHITECTURE.md §"Platform I/O Adapters"):
///   - dart:io available (native — Android, desktop):
///       platform_device_name_io.dart   →  a method channel to the Android side
///   - otherwise (web):
///       platform_device_name_web.dart  →  the browser's user agent
///
/// Both answer the same question the same way: the name the platform gives
/// this device, or `null` when it gives none. A name is a convenience, so
/// every way of not having one is `null` rather than an error.
library;

export 'platform_device_name_web.dart'
    if (dart.library.io) 'platform_device_name_io.dart';
