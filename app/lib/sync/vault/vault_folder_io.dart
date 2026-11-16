/// [VaultFolder] over a plain directory, through `dart:io`.
///
/// The implementation the test suite runs: real files in a real temporary
/// directory, the way a person's syncer would carry them. Selected by the
/// conditional export in `vault_folder_impl.dart` when `dart:io` is available.
library;

import 'dart:io';

import 'vault_folder.dart';

/// [VaultFolder] over a plain directory, through `dart:io`.
class DirectoryVaultFolder implements VaultFolder {
  DirectoryVaultFolder(this.root);

  final Directory root;

  File _file(String relativePath) {
    requireSafeVaultPath(relativePath);
    return File('${root.path}${Platform.pathSeparator}'
        '${relativePath.replaceAll('/', Platform.pathSeparator)}');
  }

  @override
  Future<List<String>> listMarkdownFiles(String subfolder) async {
    final dir = Directory(_file(subfolder).path);
    if (!await dir.exists()) return const [];
    final prefix = '${root.path}${Platform.pathSeparator}';
    final paths = <String>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File && entity.path.endsWith('.md')) {
        paths.add(entity.path.substring(prefix.length).replaceAll(
            Platform.pathSeparator, '/'));
      }
    }
    paths.sort();
    return paths;
  }

  @override
  Future<String?> read(String relativePath) async {
    final file = _file(relativePath);
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  @override
  Future<void> writeAtomically(String relativePath, String text) async {
    final target = _file(relativePath);
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.jeeves-tmp');
    await temporary.writeAsString(text, flush: true);
    await temporary.rename(target.path);
  }

  @override
  Future<void> remove(String relativePath) async {
    final file = _file(relativePath);
    if (await file.exists()) await file.delete();
  }
}

/// A [VaultFolder] over a directory on this device, by its path.
///
/// The desktop-and-test half of [openVaultFolder]; Android reaches the same
/// folder through the system picker instead.
VaultFolder openLocalVaultFolder(String path) =>
    DirectoryVaultFolder(Directory(path));
