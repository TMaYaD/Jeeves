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

  /// Counts the writes this process has made, so two of them never share the
  /// name of a temporary file.
  static int _writeCount = 0;

  /// The vault root as the file system sees it, with every symbolic link
  /// resolved.
  Future<String> _resolvedRoot() async {
    try {
      return await root.resolveSymbolicLinks();
    } on FileSystemException {
      return root.absolute.path;
    }
  }

  /// Whether [resolved] is the vault root, or inside it.
  bool _inside(String resolved, String rootPath) =>
      resolved == rootPath ||
      resolved.startsWith('$rootPath${Platform.pathSeparator}');

  /// The folder that holds [relativePath], when it is inside the vault.
  ///
  /// The path components are checked first, and then the folder itself is
  /// resolved: a folder inside the vault that is a symbolic link to somewhere
  /// else would take the read or the write outside the vault, because Dart's
  /// file operations follow such a link. A folder that does not exist yet is
  /// checked through the nearest ancestor that does.
  Future<Directory> _containedFolder(String relativePath) async {
    requireSafeVaultPath(relativePath);
    final directory = Directory(_absolute(relativePath));
    var existing = directory;
    while (!await existing.exists()) {
      final next = existing.parent;
      if (next.path == existing.path) break;
      existing = next;
    }
    final resolved = await existing.resolveSymbolicLinks();
    if (!_inside(resolved, await _resolvedRoot())) {
      throw ArgumentError.value(
          relativePath, 'path', 'resolves outside the vault folder');
    }
    return directory;
  }

  /// The file [relativePath] names, when it is inside the vault.
  ///
  /// The folder that holds it is checked, and so is the file itself: a file
  /// that is a symbolic link to somewhere else would be read from there.
  Future<File> _containedFile(String relativePath) async {
    final file = File(_absolute(relativePath));
    await _containedFolder(relativePath);
    if (await file.exists()) {
      final resolved = await file.resolveSymbolicLinks();
      if (!_inside(resolved, await _resolvedRoot())) {
        throw ArgumentError.value(
            relativePath, 'path', 'resolves outside the vault folder');
      }
    }
    return file;
  }

  String _absolute(String relativePath) =>
      '${root.path}${Platform.pathSeparator}'
      '${relativePath.replaceAll('/', Platform.pathSeparator)}';

  @override
  Future<List<String>> listMarkdownFiles(String subfolder) async {
    final dir = await _containedFolder(subfolder);
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
    final file = await _containedFile(relativePath);
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  @override
  Future<void> writeAtomically(String relativePath, String text) async {
    final target = await _containedFile(relativePath);
    await target.parent.create(recursive: true);
    // A temporary name of its own for every write: two plugin instances, or
    // two writes of one page, never share it, and the first rename does not
    // consume the second one's file. The name does not end in `.md`, so a
    // leftover is never listed as a page.
    final temporary = File('${target.path}.jeeves-tmp-${_temporarySuffix()}');
    try {
      // Created exclusively, so a name that is already there — a symbolic link
      // put there by something else — is refused rather than followed.
      await temporary.create(exclusive: true);
      await temporary.writeAsString(text, flush: true);
      await temporary.rename(target.path);
    } on Object {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  /// A suffix that no other write of this process shares.
  String _temporarySuffix() {
    _writeCount++;
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    return '${pid.toRadixString(16)}-$now-$_writeCount';
  }

  @override
  Future<void> remove(String relativePath) async {
    final file = await _containedFile(relativePath);
    if (await file.exists()) await file.delete();
  }
}

/// A [VaultFolder] over a directory on this device, by its path.
///
/// The desktop-and-test half of [openVaultFolder]; Android reaches the same
/// folder through the system picker instead.
VaultFolder openLocalVaultFolder(String path) =>
    DirectoryVaultFolder(Directory(path));
