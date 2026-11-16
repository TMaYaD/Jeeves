/// [SegmentFolder] over the Android storage-access channel (`FolderStoragePlugin`).
///
/// The location is the persisted tree URI the system folder picker returned.
/// Nothing in CI runs this half — there is no on-device tier — so it is kept to a
/// thin pass-through; the same contract is exercised over `dart:io` instead.
library;

import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'segment_folder.dart';

const MethodChannel _channel = MethodChannel('jeeves/folder');

/// Show the system folder picker; the tree URI, or null if cancelled.
Future<String?> pickAndroidFolder() => _channel.invokeMethod<String>('pickFolder');

class AndroidSegmentFolder implements SegmentFolder {
  AndroidSegmentFolder(this.treeUri);

  final String treeUri;

  Map<String, Object?> _args(String path, [Map<String, Object?> more = const {}]) =>
      {'tree': treeUri, 'path': requireSafeRelativePath(path), ...more};

  @override
  Future<List<String>> listDirectories(String directory) async =>
      ((await _channel.invokeListMethod<String>('listDirectories', _args(directory))) ?? [])
        ..sort();

  @override
  Future<List<String>> listFiles(String directory) async =>
      ((await _channel.invokeListMethod<String>('listFiles', _args(directory))) ?? [])
        ..sort();

  @override
  Future<int?> length(String path) async =>
      (await _channel.invokeMethod<num>('length', _args(path)))?.toInt();

  @override
  Future<Uint8List> read(String path, {required int offset, required int maxBytes}) async =>
      (await _channel.invokeMethod<Uint8List>(
            'read',
            _args(path, {'offset': offset, 'maxBytes': maxBytes}),
          )) ??
      Uint8List(0);

  @override
  Future<void> append(String path, Uint8List bytes) =>
      _channel.invokeMethod<void>('append', _args(path, {'bytes': bytes}));

  @override
  Future<bool> createIfAbsent(String path, Uint8List bytes) async =>
      (await _channel.invokeMethod<bool>('createIfAbsent', _args(path, {'bytes': bytes}))) ??
      false;
}
