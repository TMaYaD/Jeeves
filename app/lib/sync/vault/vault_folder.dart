/// The only way the vault plugin touches the folder: list, read,
/// write-and-rename, remove.
///
/// **The port, and nothing else.** The implementation that reaches a plain
/// directory needs `dart:io`, which the web build does not have, so it lives in
/// `vault_folder_io.dart` and is selected by the conditional export in
/// `vault_folder_impl.dart` — the same rule `sync/sync_store.dart` follows
/// (docs/ARCHITECTURE.md § "Platform I/O Adapters").
///
/// Paths are relative to the vault root and use `/` as separator, whatever the
/// platform.
library;

/// The vault's folder: pages under `Outcomes/`, `Sessions/` and `Inbox/`.
abstract class VaultFolder {
  /// Relative paths of every `.md` file under [subfolder], sorted.
  Future<List<String>> listMarkdownFiles(String subfolder);

  /// File text, or null when the file does not exist.
  Future<String?> read(String relativePath);

  /// Writes through a temporary file and a rename, so a syncer never sees a
  /// half-written page. Creates missing parent folders.
  Future<void> writeAtomically(String relativePath, String text);

  Future<void> remove(String relativePath);
}

/// A relative path made only of safe components, or an [ArgumentError].
///
/// Everything read back through a [VaultFolder] is untrusted input — another app
/// or the file syncer may have put anything there — so a name is never used as a
/// path component before it has been checked, and a path that escapes the vault
/// is refused rather than resolved.
String requireSafeVaultPath(String path) {
  if (path.isEmpty) return path;
  for (final part in path.split('/')) {
    if (part.isEmpty ||
        part == '.' ||
        part == '..' ||
        part.contains('\\') ||
        part.contains('\x00')) {
      throw ArgumentError.value(path, 'path', 'is not a safe relative path');
    }
  }
  return path;
}
