/// What happens when the folder cannot be reached while Jeeves is starting: the
/// host's cursor is kept, so the changes made while the folder was down are
/// still owed to the plugin, and a failed attach leaves a working registration
/// alone.
@TestOn('!browser')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/device_key_store.dart';
import 'package:jeeves/sync/folder/folder_metadata.dart';
import 'package:jeeves/sync/folder/folder_setup.dart';
import 'package:jeeves/sync/folder/op_log_folder_plugin.dart';
import 'package:jeeves/sync/folder/segment_folder.dart';
import 'package:jeeves/sync/folder_sync_controller.dart';
import 'package:jeeves/sync/host/sync_host_service.dart';

import 'folder_harness.dart';
import '../host/host_harness.dart';

const String _userId = 'folder-attach-user';
const String _beforeOutcomeId = '3f2d1c4e-5a6b-4c8d-9e0f-1a2b3c4d5e6f';
const String _duringOutcomeId = '4a3e2d5f-6b7c-4d9e-8f01-2b3c4d5e6f70';

/// A folder that can be made unreachable: every call fails while it is down.
class _FlakyFolder implements SegmentFolder {
  _FlakyFolder(this.inner);

  final SegmentFolder inner;
  bool down = false;

  Never _unreachable() =>
      throw const FileSystemException('the folder is not there');

  @override
  Future<List<String>> listDirectories(String directory) async =>
      down ? _unreachable() : inner.listDirectories(directory);

  @override
  Future<List<String>> listFiles(String directory) async =>
      down ? _unreachable() : inner.listFiles(directory);

  @override
  Future<int?> length(String path) async =>
      down ? _unreachable() : inner.length(path);

  @override
  Future<Uint8List> read(String path,
      {required int offset, required int maxBytes}) async =>
      down ? _unreachable() : inner.read(path, offset: offset, maxBytes: maxBytes);

  @override
  Future<void> append(String path, Uint8List bytes) async =>
      down ? _unreachable() : inner.append(path, bytes);

  @override
  Future<bool> createIfAbsent(String path, Uint8List bytes) async =>
      down ? _unreachable() : inner.createIfAbsent(path, bytes);
}

void main() {
  late Directory directory;
  late FolderDevice b;
  late HostDevice a;
  late SyncHostService host;
  late _FlakyFolder folder;
  late InMemoryDeviceKeyStore keyStore;
  late FolderSyncController controller;
  var enrolled = false;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('folder-attach-');
    addTearDown(() => directory.deleteSync(recursive: true));
    b = await FolderDevice.open('b', directory);
    addTearDown(b.close);
    await b.bind();
    a = HostDevice.open('a');
    addTearDown(a.close);
    host = await a.startHost();
    addTearDown(host.stopPlugins);
    folder = _FlakyFolder(DartIoSegmentFolder(directory));
    keyStore = InMemoryDeviceKeyStore();
    controller = FolderSyncController(
      host: host,
      database: a.sync,
      keyStore: keyStore,
      openFolder: (_) => folder,
      isEnrolled: () async => enrolled,
      nowMs: () => a.wall.nowMs,
    );
  });

  String memberIdOfA() => memberUuidFromNodeId(host.deviceNodeId);

  /// Pair the two devices, the way the screen does: each pins the key the other
  /// shows.
  Future<void> pairBothWays() async {
    final summary = await controller.summary();
    final bCandidate = summary!.members.firstWhere((c) => c.memberId == b.memberId);
    await controller.pair(b.memberId, bCandidate.signPublicKey!);
    final aCandidate =
        (await b.setup.candidates(b.folderId)).firstWhere((c) => c.memberId == memberIdOfA());
    await b.setup.pair(b.folderId, memberIdOfA(),
        expectedSignPublicKey: aCandidate.signPublicKey!);
    await b.attach();
  }

  Future<int> outcomeCount(FolderDevice device) async =>
      (await device.device.domain.customSelect('SELECT id FROM todos').get()).length;

  test('a failed attach keeps the cursor, so a change made while the folder was down is delivered',
      () async {
    // The device is set up in the folder but not attached: the state a launch
    // finds when the folder cannot be reached.
    final setup = FolderSyncSetup(
      database: a.sync,
      folder: folder,
      keyStore: keyStore,
      isEnrolled: () async => false,
      nowMs: () => a.wall.nowMs,
    );
    await setup.bind(
      folderLocation: directory.path,
      deviceNodeIdHex: host.deviceNodeId,
      deviceLabel: 'a',
    );
    await pairBothWays();
    await a.domain.todoDao.insertOutcome(
        id: _beforeOutcomeId, title: 'Before', userId: _userId);

    folder.down = true;
    await expectLater(controller.resume(), throwsA(isA<FileSystemException>()));

    // The cursor is kept: only turning folder sync off forgets it, so the
    // changes made from now on are still owed to this plugin.
    expect(await host.cursorOf(opLogFolderPluginId), isNotNull);

    await a.domain.todoDao.insertOutcome(
        id: _duringOutcomeId, title: 'During', userId: _userId);

    folder.down = false;
    await controller.resume();
    await host.deliverAll();

    await b.plugin!.scan();
    expect(await outcomeCount(b), 2,
        reason: 'the change made while the folder was down reaches the peer');
  });

  test('a failed attach leaves the working registration in place', () async {
    await controller.turnOn(
        location: directory.path, acknowledgedUnencrypted: true);
    await pairBothWays();
    final attached = host.pluginOf(opLogFolderPluginId);
    expect(attached, isNotNull);

    // The folder goes away while there is still something to write.
    folder.down = true;
    await a.domain.todoDao.insertOutcome(
        id: _beforeOutcomeId, title: 'Before', userId: _userId);
    await host.deliverAll();

    await expectLater(controller.resume(), throwsA(isA<FileSystemException>()));

    expect(host.pluginOf(opLogFolderPluginId), same(attached),
        reason: 'the failed attach did not take the working registration away');

    // The plugin that is still attached carries on.
    folder.down = false;
    await a.domain.todoDao.insertOutcome(
        id: _duringOutcomeId, title: 'During', userId: _userId);
    await host.deliverAll();
    await controller.scanNow();

    await b.plugin!.scan();
    expect(await outcomeCount(b), 2);
  });

  test('a binding turned off because the device enrolled leaves no cursor behind', () async {
    await controller.turnOn(
        location: directory.path, acknowledgedUnencrypted: true);
    expect(await host.cursorOf(opLogFolderPluginId), isNotNull);

    enrolled = true;
    await controller.resume();

    expect(await controller.activeBinding(), isNull);
    expect(await host.cursorOf(opLogFolderPluginId), isNull,
        reason: 'a stale cursor would hold back what the host may prune');
  });
}
