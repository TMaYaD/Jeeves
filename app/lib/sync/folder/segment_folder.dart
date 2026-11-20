/// Where a folder's files live: the seam between the plugin and a file system.
///
/// The plugin reads and writes only through this, using `/`-separated paths
/// relative to the chosen folder. The production implementations are
/// [DartIoSegmentFolder] and, on Android, one over a small platform channel. Both
/// are real implementations of the same contract, so nothing here is a mock.
///
/// Everything read back through it is untrusted input (another app or the file
/// syncer may have put anything there): callers must check a name before using it
/// as a path component, and implementations refuse a path that escapes the folder.
library;

import 'dart:io';
import 'dart:typed_data';

abstract class SegmentFolder {
  /// Names of the sub-directories of [directory] (the folder root when empty).
  Future<List<String>> listDirectories(String directory);

  /// Names of the files in [directory]. Missing directory → empty.
  Future<List<String>> listFiles(String directory);

  /// Size of [path] in bytes, or null if it does not exist.
  Future<int?> length(String path);

  /// Up to [maxBytes] bytes of [path] from [offset]. Missing file → empty.
  Future<Uint8List> read(String path, {required int offset, required int maxBytes});

  /// Append [bytes] to [path], creating it (and its directory) if needed.
  Future<void> append(String path, Uint8List bytes);

  /// Create [path] with [bytes] unless it already exists. Returns whether it was
  /// created.
  Future<bool> createIfAbsent(String path, Uint8List bytes);
}

/// A relative path made only of safe components, or an [ArgumentError].
String requireSafeRelativePath(String path) {
  if (path.isEmpty) return path;
  for (final part in path.split('/')) {
    if (part.isEmpty || part == '.' || part == '..' || part.contains('\\') || part.contains('\x00')) {
      throw ArgumentError.value(path, 'path', 'is not a safe relative path');
    }
  }
  return path;
}

/// [SegmentFolder] over `dart:io`.
class DartIoSegmentFolder implements SegmentFolder {
  DartIoSegmentFolder(this.root);

  final Directory root;

  String _resolve(String path) {
    requireSafeRelativePath(path);
    return path.isEmpty ? root.path : '${root.path}/$path';
  }

  @override
  Future<List<String>> listDirectories(String directory) async {
    final dir = Directory(_resolve(directory));
    if (!await dir.exists()) return const [];
    return [
      await for (final entity in dir.list(followLinks: false))
        if (entity is Directory) entity.uri.pathSegments.where((s) => s.isNotEmpty).last,
    ]..sort();
  }

  @override
  Future<List<String>> listFiles(String directory) async {
    final dir = Directory(_resolve(directory));
    if (!await dir.exists()) return const [];
    return [
      await for (final entity in dir.list(followLinks: false))
        if (entity is File) entity.uri.pathSegments.last,
    ]..sort();
  }

  @override
  Future<int?> length(String path) async {
    final file = File(_resolve(path));
    if (!await file.exists()) return null;
    return file.length();
  }

  @override
  Future<Uint8List> read(String path, {required int offset, required int maxBytes}) async {
    final file = File(_resolve(path));
    if (!await file.exists()) return Uint8List(0);
    final handle = await file.open();
    try {
      final size = await handle.length();
      if (offset >= size) return Uint8List(0);
      await handle.setPosition(offset);
      final wanted = size - offset < maxBytes ? size - offset : maxBytes;
      return await handle.read(wanted);
    } finally {
      await handle.close();
    }
  }

  @override
  Future<void> append(String path, Uint8List bytes) async {
    final file = File(_resolve(path));
    await file.parent.create(recursive: true);
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.writeFrom(bytes);
      await handle.flush();
    } finally {
      await handle.close();
    }
  }

  @override
  Future<bool> createIfAbsent(String path, Uint8List bytes) async {
    final file = File(_resolve(path));
    await file.parent.create(recursive: true);
    try {
      await file.create(exclusive: true);
    } on PathExistsException {
      return false;
    }
    await file.writeAsBytes(bytes, flush: true);
    return true;
  }
}
