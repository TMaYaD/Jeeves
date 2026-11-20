/// The web half of the vault's folder.
///
/// The web build has no folders to sync through — the vault's tile is not shown
/// there at all — so this half exists only so the code compiles, and it says so
/// loudly if anything asks it for a folder anyway. Selected by the conditional
/// export in `vault_folder_impl.dart` when `dart:io` is unavailable.
library;

import 'vault_folder.dart';

/// Always fails: a browser has no directory to sync a vault through.
class DirectoryVaultFolder implements VaultFolder {
  DirectoryVaultFolder(String path) {
    throw UnsupportedError(
      'the vault needs a folder on this device, and this platform has none '
      '(path: $path)',
    );
  }

  @override
  Future<List<String>> listMarkdownFiles(String subfolder) async =>
      throw UnsupportedError('the vault needs a folder, and this platform has none');

  @override
  Future<String?> read(String relativePath) async =>
      throw UnsupportedError('the vault needs a folder, and this platform has none');

  @override
  Future<void> writeAtomically(String relativePath, String text) async =>
      throw UnsupportedError('the vault needs a folder, and this platform has none');

  @override
  Future<void> remove(String relativePath) async =>
      throw UnsupportedError('the vault needs a folder, and this platform has none');
}

/// Always fails: a browser has no directory to sync a vault through.
VaultFolder openLocalVaultFolder(String path) =>
    throw UnsupportedError('the vault needs a folder, and this platform has none');
