// Platform-adaptive PowerSync database opener.
//
// Import this file everywhere that needs to open a PowerSyncDatabase.
// The Dart compiler selects the right implementation at build time:
//   - dart:io  available (native — Android, iOS, macOS, Linux, Windows):
//       powersync_storage_io.dart  →  path_provider + file path
//   - dart:html available (web):
//       powersync_storage_web.dart →  OPFS-backed WebPowerSyncOpenFactory
//   - neither (compile-time stub only):
//       powersync_storage_stub.dart → throws UnsupportedError
//
// See docs/ARCHITECTURE.md §"Platform I/O Adapters" for the design rationale
// and the rule that governs when to add a new adapter file.
export 'powersync_storage_stub.dart'
    if (dart.library.io) 'powersync_storage_io.dart'
    if (dart.library.html) 'powersync_storage_web.dart';
