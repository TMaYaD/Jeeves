// Platform-adaptive opener for the op-log store.
//
// Production sync wiring (#553 Phase 2).
//
// Import this file everywhere that needs to open the [SyncDatabase]. The Dart
// compiler selects the implementation at build time, the same rule
// `powersync_storage.dart` follows (docs/ARCHITECTURE.md §"Platform I/O
// Adapters"):
//   - dart:io available (native — Android, iOS, macOS, Linux, Windows):
//       sync_store_io.dart   →  path_provider + a file of its own
//   - otherwise (web, and the analyser's platform-agnostic view):
//       sync_store_stub.dart →  throws UnsupportedError
//
// There is no web adapter and that is a decision, not a gap: the op-log stack's
// fleet for the #553 cutover is one Android phone, and a browser adapter would
// be an untested claim rather than a capability. A web build still *compiles* —
// which is the whole reason the conditional export exists.
export 'sync_store_stub.dart' if (dart.library.io) 'sync_store_io.dart';
