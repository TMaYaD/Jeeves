/// The platform's [VaultFolder] implementation, chosen at build time.
///
/// Import this where the concrete folder is needed. The Dart compiler selects
/// the implementation the same rule `sync/sync_store.dart` and
/// `database/domain_store.dart` follow (docs/ARCHITECTURE.md § "Platform I/O
/// Adapters"):
///   - dart:io available (native — Android, iOS, macOS, Linux, Windows):
///       vault_folder_io.dart    →  a plain directory
///   - otherwise (web, and the analyser's platform-agnostic view):
///       vault_folder_stub.dart  →  throws UnsupportedError
///
/// There is no web adapter and that is a decision, not a gap: the web build has
/// no folder to sync through, and the vault's tile is not shown there. A web
/// build still *compiles* — which is the whole reason the conditional export
/// exists.
library;

export 'vault_folder_stub.dart' if (dart.library.io) 'vault_folder_io.dart';
