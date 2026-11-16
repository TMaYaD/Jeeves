/// A device syncing through a shared folder: a real [HostDevice] (both stores, real
/// DAOs, real host) with the op-log folder plugin attached over a real directory.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:jeeves/sync/device_key_store.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/folder/folder_metadata.dart';
import 'package:jeeves/sync/folder/folder_setup.dart';
import 'package:jeeves/sync/folder/op_log_folder_plugin.dart';
import 'package:jeeves/sync/folder/segment_folder.dart';
import 'package:jeeves/sync/folder/segment_format.dart';
import 'package:jeeves/sync/host/sync_host_service.dart';

import '../host/host_harness.dart';

class FolderDevice {
  FolderDevice._(this.device, this.host, this.setup, this.keyStore, this.files);

  final HostDevice device;
  final SyncHostService host;
  final FolderSyncSetup setup;
  final InMemoryDeviceKeyStore keyStore;
  final DartIoSegmentFolder files;
  late String folderId;
  OpLogFolderPlugin? plugin;
  bool enrolled = false;

  static Future<FolderDevice> open(
    String label,
    Directory folderDirectory, {
    HostDevice? existing,
  }) async {
    final device = existing ?? HostDevice.open(label);
    final host = await device.startHost();
    final files = DartIoSegmentFolder(folderDirectory);
    final keyStore = InMemoryDeviceKeyStore();
    late FolderDevice built;
    final setup = FolderSyncSetup(
      database: device.sync,
      folder: files,
      keyStore: keyStore,
      isEnrolled: () async => built.enrolled,
      nowMs: () => device.wall.nowMs,
    );
    built = FolderDevice._(device, host, setup, keyStore, files);
    return built;
  }

  String get memberId => memberUuidFromNodeId(host.deviceNodeId);

  Future<void> bind() async {
    folderId = await setup.bind(
      folderLocation: 'test',
      deviceNodeIdHex: host.deviceNodeId,
      deviceLabel: device.label,
    );
  }

  OpLogFolderPlugin buildPlugin({int? rollBytes, Duration? rollAge}) => OpLogFolderPlugin(
        database: device.sync,
        folder: files,
        keyStore: keyStore,
        folderId: folderId,
        isEnrolled: () async => enrolled,
        nowMs: () => device.wall.nowMs,
        rollBytes: rollBytes ?? segmentRollBytes,
        rollAge: rollAge ?? segmentRollAge,
      );

  Future<void> attach({int? rollBytes, Duration? rollAge}) async {
    plugin = buildPlugin(rollBytes: rollBytes, rollAge: rollAge);
    await host.attach(plugin!);
  }

  /// Pairs as the screen does: pins the key from the candidate list the person
  /// saw, unless [shownKey] says otherwise.
  Future<void> pairWith(FolderDevice other, {Uint8List? shownKey}) async {
    final key = shownKey ??
        (await setup.candidates(folderId))
            .firstWhere((candidate) => candidate.memberId == other.memberId)
            .signPublicKey ??
        Uint8List(32); // a member with a problem has no key; setup refuses it itself
    await setup.pair(folderId, other.memberId, expectedSignPublicKey: key);
  }

  Future<void> close() => device.close();
}

/// Settle [from]'s outbound changes, then let [to] read them and settle.
Future<void> propagate(FolderDevice from, FolderDevice to) async {
  await from.host.deliverAll();
  await to.plugin!.scan();
  await to.host.deliverAll();
}

/// Everything under `ops/` as `path → bytes`, for byte-for-byte comparison.
Map<String, Uint8List> snapshotOps(Directory root, {String? member}) {
  final result = <String, Uint8List>{};
  final ops = Directory('${root.path}/$opsDirectoryName');
  if (!ops.existsSync()) return result;
  for (final entity in ops.listSync(recursive: true)) {
    if (entity is! File) continue;
    final relative = entity.path.substring(root.path.length + 1);
    if (member != null && !relative.startsWith('$opsDirectoryName/$member/')) continue;
    result[relative] = entity.readAsBytesSync();
  }
  return result;
}

/// Every envelope in a member's segments, in file order.
List<Uint8List> envelopesOf(Directory root, String memberId) {
  final directory = Directory('${root.path}/$opsDirectoryName/$memberId');
  final names = [
    for (final file in directory.listSync().whereType<File>())
      if (parseSegmentFileName(file.uri.pathSegments.last) != null) file.uri.pathSegments.last,
  ]..sort();
  return [
    for (final name in names)
      ...readRecords(File('${directory.path}/$name').readAsBytesSync())
          .map((record) => record.envelope),
  ];
}

OpHeader headerOf(Uint8List envelope) => OpHeader.parse(envelope);
