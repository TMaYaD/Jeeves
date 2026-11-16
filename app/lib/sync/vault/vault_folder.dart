import 'dart:io';

/// The only way the vault plugin touches the folder: list, read,
/// write-and-rename, remove. Paths are relative to the vault root and use
/// `/` as separator, whatever the platform.
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

/// [VaultFolder] over a plain directory, through `dart:io`.
class DirectoryVaultFolder implements VaultFolder {
  DirectoryVaultFolder(this.root);

  final Directory root;

  File _file(String relativePath) =>
      File('${root.path}${Platform.pathSeparator}'
          '${relativePath.replaceAll('/', Platform.pathSeparator)}');

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
