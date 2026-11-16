/// What the settings screen drives: turn folder sync on or off, pair, and bring an
/// active binding back at launch.
///
/// The decisions live in [FolderSyncSetup] and [OpLogFolderPlugin]; this only
/// composes them with the host and the platform's folder access.
library;

import '../host/sync_host_service.dart';
import '../device_key_store.dart';
import '../sync_database.dart';
import 'folder_setup.dart';
import 'op_log_folder_plugin.dart';
import 'segment_folder.dart';

/// Opens a [SegmentFolder] for a stored location (a path, or an Android tree URI).
typedef SegmentFolderOpener = SegmentFolder Function(String location);

/// How often an attached plugin looks for other devices' changes.
const Duration folderScanInterval = Duration(seconds: 30);

class FolderSyncSummary {
  const FolderSyncSummary({
    required this.folderId,
    required this.folderLocation,
    required this.deviceLabel,
    required this.fingerprint,
    required this.members,
  });

  final String folderId;
  final String folderLocation;
  final String deviceLabel;

  /// This device's key fingerprint, for the person to compare on the other device.
  final String fingerprint;
  final List<FolderMemberCandidate> members;
}

class FolderSyncController {
  FolderSyncController({
    required this.host,
    required this.database,
    required this.keyStore,
    required this.openFolder,
    required this.isEnrolled,
    required this.nowMs,
  });

  final SyncHostService host;
  final SyncDatabase database;
  final DeviceKeyStore keyStore;
  final SegmentFolderOpener openFolder;
  final EnrolmentCheck isEnrolled;
  final int Function() nowMs;

  FolderSyncSetup _setupFor(SegmentFolder folder) => FolderSyncSetup(
        database: database,
        folder: folder,
        keyStore: keyStore,
        isEnrolled: isEnrolled,
        nowMs: nowMs,
      );

  Future<FolderSyncBindingRow?> activeBinding() => (database.select(database.folderSyncBindings)
        ..where((row) => row.isActive.equals(true))
        ..limit(1))
      .getSingleOrNull();

  /// Bind this device to the folder at [location] and attach the plugin.
  ///
  /// [acknowledgedUnencrypted] is the person's yes to "Jeeves does not encrypt this
  /// folder"; without it nothing is written.
  Future<void> turnOn({
    required String location,
    required String deviceLabel,
    required bool acknowledgedUnencrypted,
  }) async {
    if (!acknowledgedUnencrypted) {
      throw const FolderSyncRefusal(
          'Confirm that you understand the folder is not encrypted first.');
    }
    final folder = openFolder(location);
    final folderId = await _setupFor(folder).bind(
      folderLocation: location,
      deviceNodeIdHex: host.deviceNodeId,
      deviceLabel: deviceLabel,
    );
    await _attach(folderId, folder);
  }

  /// Attach the plugin for the binding that is still turned on, at launch. A
  /// device that has since been signed in or enrolled leaves it detached.
  Future<void> resume() async {
    final binding = await activeBinding();
    if (binding == null) return;
    await _attach(binding.folderId, openFolder(binding.folderLocation));
  }

  Future<void> _attach(String folderId, SegmentFolder folder) async {
    final plugin = OpLogFolderPlugin(
      database: database,
      folder: folder,
      keyStore: keyStore,
      folderId: folderId,
      isEnrolled: isEnrolled,
      nowMs: nowMs,
      scanInterval: folderScanInterval,
    );
    try {
      await host.attach(plugin);
    } on Object {
      await host.detach(opLogFolderPluginId, forgetCursor: true);
      rethrow;
    }
  }

  Future<FolderSyncSummary?> summary() async {
    final binding = await activeBinding();
    if (binding == null) return null;
    final setup = _setupFor(openFolder(binding.folderLocation));
    return FolderSyncSummary(
      folderId: binding.folderId,
      folderLocation: binding.folderLocation,
      deviceLabel: binding.deviceLabel,
      fingerprint: await setup.ownFingerprint(binding.folderId),
      members: await setup.candidates(binding.folderId),
    );
  }

  /// Pin [memberId] after the person compared fingerprints, and read it now.
  Future<void> pair(String memberId) async {
    final binding = await activeBinding();
    if (binding == null) return;
    await _setupFor(openFolder(binding.folderLocation)).pair(binding.folderId, memberId);
  }

  /// Turn folder sync off. Files already in the folder stay there.
  Future<void> turnOff() async {
    final binding = await activeBinding();
    if (binding == null) return;
    await host.detach(opLogFolderPluginId, forgetCursor: true);
    await _setupFor(openFolder(binding.folderLocation)).unbind(binding.folderId);
  }
}
