/// [VaultFolder] over the Android storage-access channel.
///
/// The vault reaches a shared folder the way the person chose it: the system
/// folder picker (`ACTION_OPEN_DOCUMENT_TREE`), whose tree URI is persisted by
/// the platform. Jeeves asks for no broad storage permission — the picker
/// grants access to the one folder the person picked.
///
/// **The channel is the op-log folder plugin's** (`jeeves/folder`, the one
/// #917's in-app Kotlin document-tree channel provides). This file adds no
/// second channel and no second picker: it is a second *client* of the one
/// channel, over the same operations plus the two the vault needs and the op
/// log does not — write-and-rename and remove.
///
/// Nothing in CI runs this half — there is no on-device tier — so it is kept to a
/// thin pass-through; the same contract is exercised over `dart:io` instead.
library;

import 'dart:convert';

import 'package:flutter/services.dart';

import 'vault_folder.dart';

const MethodChannel _channel = MethodChannel('jeeves/folder');

/// Show the system folder picker; the tree URI, or null if cancelled.
///
/// The URI is what the vault setting stores: it is the person's folder, and it
/// is this device's own reference to it — another device reaches the same
/// folder through its own picker, or through whatever syncer carries it.
Future<String?> pickAndroidVaultFolder() =>
    _channel.invokeMethod<String>('pickFolder');

/// A [VaultFolder] over the folder the system picker returned.
class AndroidVaultFolder implements VaultFolder {
  AndroidVaultFolder(this.treeUri);

  /// The persisted tree URI of the picked folder.
  final String treeUri;

  Map<String, Object?> _args(String path, [Map<String, Object?> more = const {}]) =>
      {'tree': treeUri, 'path': requireSafeVaultPath(path), ...more};

  @override
  Future<List<String>> listMarkdownFiles(String subfolder) async {
    final paths = <String>[];
    await _walk(requireSafeVaultPath(subfolder), paths);
    paths.sort();
    return paths;
  }

  /// The channel lists one directory at a time, so the walk is driven from here
  /// rather than asking the platform for a recursive listing it does not have.
  Future<void> _walk(String directory, List<String> paths) async {
    final files = await _channel.invokeListMethod<String>(
          'listFiles',
          _args(directory),
        ) ??
        const <String>[];
    for (final file in files) {
      if (!file.endsWith('.md')) continue;
      paths.add(directory.isEmpty ? file : '$directory/$file');
    }
    final directories = await _channel.invokeListMethod<String>(
          'listDirectories',
          _args(directory),
        ) ??
        const <String>[];
    for (final child in directories) {
      await _walk(directory.isEmpty ? child : '$directory/$child', paths);
    }
  }

  @override
  Future<String?> read(String relativePath) async {
    final length =
        await _channel.invokeMethod<num>('length', _args(relativePath));
    if (length == null) return null;
    final bytes = await _channel.invokeMethod<Uint8List>(
      'read',
      _args(relativePath, {'offset': 0, 'maxBytes': length.toInt()}),
    );
    return utf8.decode(bytes ?? Uint8List(0));
  }

  @override
  Future<void> writeAtomically(String relativePath, String text) =>
      _channel.invokeMethod<void>(
        'writeAtomically',
        _args(relativePath, {'bytes': utf8.encode(text)}),
      );

  @override
  Future<void> remove(String relativePath) =>
      _channel.invokeMethod<void>('remove', _args(relativePath));
}
