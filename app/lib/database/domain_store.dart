// Platform-adaptive opener for the domain read model's store.
//
// Import this file everywhere that needs to open the [GtdDatabase]'s storage. The
// Dart compiler selects the implementation at build time, the same rule
// `sync/sync_store.dart` follows (docs/ARCHITECTURE.md §"Platform I/O
// Adapters"):
//   - dart:io available (native — Android, iOS, macOS, Linux, Windows):
//       domain_store_io.dart   →  path_provider + jeeves_domain.sqlite
//   - otherwise (web, and the analyser's platform-agnostic view):
//       domain_store_stub.dart →  throws UnsupportedError
//
// There is no web adapter and that is a decision, not a gap: the fleet is one
// Android phone, and a browser adapter would be an untested claim rather than a
// capability. A web build still *compiles* — which is the whole reason the
// conditional export exists.
export 'domain_store_stub.dart' if (dart.library.io) 'domain_store_io.dart';
