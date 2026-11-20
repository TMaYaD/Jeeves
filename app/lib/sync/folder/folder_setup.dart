/// Choosing a folder, and pairing with the devices found in it.
///
/// Setup is the only place that creates `folder.json` and this device's
/// `member.json`, and the only place that mints this device's signing seed for a
/// folder. The seed stays behind [DeviceKeyStore]; nothing here writes it, logs it
/// or puts it next to the folder.
///
/// The no-downgrade rule: a device that is signed in or enrolled with the sync
/// server never binds or attaches a folder, so a folder never holds a plaintext
/// copy of data that is, or could become, encrypted under a Workspace key.
library;

import 'dart:math';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../device_key_store.dart';
import '../envelope.dart';
import '../sync_database.dart';
import 'folder_metadata.dart';
import 'segment_folder.dart';
import 'segment_format.dart' show firstSegmentNumber;

/// Whether this device is signed in or enrolled with the sync server.
typedef EnrolmentCheck = Future<bool> Function();

/// Why folder sync cannot be turned on or used. The message is for the person.
class FolderSyncRefusal implements Exception {
  const FolderSyncRefusal(this.message);
  final String message;

  @override
  String toString() => message;
}

const String enrolledRefusalMessage =
    'This device is signed in to the sync server. Folder sync is only for '
    'devices that are not.';

/// A member directory found in the folder, as the pairing screen shows it.
class FolderMemberCandidate {
  const FolderMemberCandidate({
    required this.memberId,
    required this.deviceLabel,
    required this.fingerprint,
    required this.isPaired,
    this.signPublicKey,
    this.problem,
  });

  final String memberId;
  final String deviceLabel;

  /// Empty when [problem] is set.
  final String fingerprint;

  /// The key [fingerprint] was computed from; null when [problem] is set. Pairing
  /// pins exactly this key, so the person pairs what they compared.
  final Uint8List? signPublicKey;
  final bool isPaired;

  /// Why this member cannot be paired, or null.
  final String? problem;
}

class FolderSyncSetup {
  FolderSyncSetup({
    required this.database,
    required this.folder,
    required this.keyStore,
    required this.isEnrolled,
    required this.nowMs,
    Random? random,
  }) : _random = random ?? Random.secure();

  final SyncDatabase database;
  final SegmentFolder folder;
  final DeviceKeyStore keyStore;
  final EnrolmentCheck isEnrolled;
  final int Function() nowMs;
  final Random _random;

  /// Bind this device to [folder]: read `folder.json`, or create the folder's
  /// metadata when the folder is empty; write this device's `member.json`; mint its
  /// signing key. Idempotent for a device that is already bound to the same folder.
  ///
  /// [folderLocation] is what the app stores to find the folder again.
  Future<String> bind({
    required String folderLocation,
    required String deviceNodeIdHex,
    required String deviceLabel,
  }) async {
    if (await isEnrolled()) throw const FolderSyncRefusal(enrolledRefusalMessage);
    if (deviceLabel.isEmpty || deviceLabel.length > maxDeviceLabelLength) {
      throw const FolderSyncRefusal('Give this device a short name.');
    }
    final memberId = memberUuidFromNodeId(deviceNodeIdHex);
    final folderId = await _readOrCreateFolderFile();

    final existing = await (database.select(database.folderSyncBindings)
          ..where((row) => row.folderId.equals(folderId)))
        .getSingleOrNull();
    if (existing != null) {
      if (existing.memberId != memberId) {
        throw const FolderSyncRefusal('This device is already set up in this folder.');
      }
      if ((await keyStore.read(folderId)) == null) {
        throw const FolderSyncRefusal(
            'This device has lost its key for this folder, so it cannot continue '
            'its changes there. Choose a new folder.');
      }
      await (database.update(database.folderSyncBindings)
            ..where((row) => row.folderId.equals(folderId)))
          .write(FolderSyncBindingsCompanion(
        isActive: const Value(true),
        // Changes made while it was off never reached the plugin, so the next
        // start uploads the merged state again; a receiver merges it as a no-op.
        snapshotEnqueued: const Value(false),
        folderLocation: Value(folderLocation),
        deviceLabel: Value(deviceLabel),
      ));
      return folderId;
    }

    final ownDirectory = '$opsDirectoryName/$memberId';
    if ((await folder.listFiles(ownDirectory)).isNotEmpty) {
      throw const FolderSyncRefusal(
          'This folder already holds changes written by this device that this '
          'device cannot continue. Choose a new folder.');
    }

    final seed = Uint8List.fromList(List<int>.generate(32, (_) => _random.nextInt(256)));
    final signer = await EnvelopeSigner.fromSeed(seed);
    await keyStore.write(
      folderId,
      StoredDeviceKeys(memberId: memberId, signSeed: seed, kexSeed: Uint8List(32)),
    );
    final created = await folder.createIfAbsent(
      '$ownDirectory/$memberFileName',
      MemberFile(
        folderId: folderId,
        memberId: memberId,
        signPublicKey: signer.signPublicKey,
        deviceLabel: deviceLabel,
      ).encode(),
    );
    if (!created) {
      await keyStore.clear(folderId);
      throw const FolderSyncRefusal(
          'This folder already holds files for this device. Choose a new folder.');
    }
    await database.into(database.folderSyncBindings).insert(
          FolderSyncBindingsCompanion.insert(
            folderId: folderId,
            folderLocation: folderLocation,
            memberId: memberId,
            deviceLabel: deviceLabel,
            isActive: true,
            snapshotEnqueued: false,
            nextAuthorSeq: 1,
            segmentNumber: firstSegmentNumber,
            segmentLengthBytes: 0,
            lastEnqueuedSequence: 0,
          ),
        );
    return folderId;
  }

  Future<String> _readOrCreateFolderFile() async {
    Future<String?> read() async {
      final length = await folder.length(folderFileName);
      if (length == null) return null;
      if (length > maxMetadataFileBytes) {
        throw const FolderSyncRefusal('folder.json is too large to be a Jeeves folder file.');
      }
      final bytes = await folder.read(folderFileName, offset: 0, maxBytes: maxMetadataFileBytes);
      try {
        return FolderFile.parse(bytes).folderId;
      } on FolderMetadataRefusal catch (refusal) {
        throw FolderSyncRefusal(refusal.message);
      }
    }

    final found = await read();
    if (found != null) return found;
    if ((await folder.listDirectories('')).contains(opsDirectoryName)) {
      throw const FolderSyncRefusal(
          'This folder is still syncing. Try again in a moment.');
    }
    final created = FolderFile(folderId: const Uuid().v4());
    if (!await folder.createIfAbsent(folderFileName, created.encode())) {
      return (await read()) ??
          (throw const FolderSyncRefusal('This folder is still syncing. Try again.'));
    }
    return created.folderId;
  }

  /// Turn the folder off for this device. Files already in the folder stay there
  /// (and on every device the file syncer copies them to); the author state is kept
  /// so turning the same folder back on continues the same chain.
  Future<void> unbind(String folderId) async {
    await (database.update(database.folderSyncBindings)
          ..where((row) => row.folderId.equals(folderId)))
        .write(const FolderSyncBindingsCompanion(isActive: Value(false)));
  }

  /// The members found in the folder besides this device, each with whether it is
  /// paired. Only each member's `member.json` is read.
  Future<List<FolderMemberCandidate>> candidates(String folderId) async {
    final binding = await _binding(folderId);
    final paired = {
      for (final peer in await (database.select(database.folderPeers)
                ..where((row) => row.folderId.equals(folderId)))
              .get())
        peer.memberId,
    };
    final result = <FolderMemberCandidate>[];
    for (final name in await folder.listDirectories(opsDirectoryName)) {
      if (!isCanonicalUuid(name) || name == binding.memberId) continue;
      try {
        final member = await _readMember(folderId, name);
        result.add(FolderMemberCandidate(
          memberId: name,
          deviceLabel: member.deviceLabel,
          fingerprint: keyFingerprint(member.signPublicKey),
          isPaired: paired.contains(name),
          signPublicKey: member.signPublicKey,
        ));
      } on FolderMetadataRefusal catch (refusal) {
        result.add(FolderMemberCandidate(
          memberId: name,
          deviceLabel: '',
          fingerprint: '',
          isPaired: paired.contains(name),
          problem: refusal.message,
        ));
      }
    }
    return result;
  }

  /// Pin [memberId]'s key. The person has compared its fingerprint on both
  /// devices before calling this; nothing is read from a member until then.
  /// [expectedSignPublicKey] is the key whose fingerprint they compared: if the
  /// member's file holds another key now, nothing is pinned.
  Future<void> pair(
    String folderId,
    String memberId, {
    required Uint8List expectedSignPublicKey,
  }) async {
    if (await isEnrolled()) throw const FolderSyncRefusal(enrolledRefusalMessage);
    final binding = await _binding(folderId);
    if (!isCanonicalUuid(memberId) || memberId == binding.memberId) {
      throw const FolderSyncRefusal('That is not another device in this folder.');
    }
    final MemberFile member;
    try {
      member = await _readMember(folderId, memberId);
    } on FolderMetadataRefusal catch (refusal) {
      throw FolderSyncRefusal(refusal.message);
    }
    if (!sameBytes(expectedSignPublicKey, member.signPublicKey)) {
      throw const FolderSyncRefusal(
          "This device's file changed while you were checking it. Look at its "
          'fingerprint again.');
    }
    final existing = await (database.select(database.folderPeers)
          ..where((row) => row.folderId.equals(folderId) & row.memberId.equals(memberId)))
        .getSingleOrNull();
    if (existing != null) {
      if (!sameBytes(Uint8List.fromList(existing.signPublicKey), member.signPublicKey)) {
        throw const FolderSyncRefusal(
            "This device's key changed since you paired it. Jeeves will not trust "
            'the new key automatically.');
      }
      return;
    }
    await database.into(database.folderPeers).insert(
          FolderPeersCompanion.insert(
            folderId: folderId,
            memberId: memberId,
            signPublicKey: member.signPublicKey,
            deviceLabel: member.deviceLabel,
            pairedAtMs: nowMs(),
            cursorSegment: firstSegmentNumber,
            cursorOffsetBytes: 0,
            headAuthorSeq: 0,
          ),
        );
  }

  /// This device's own key fingerprint in [folderId], for the person to compare.
  Future<String> ownFingerprint(String folderId) async {
    final keys = await keyStore.read(folderId);
    if (keys == null) {
      throw const FolderSyncRefusal('This device has no key for this folder.');
    }
    final signer = await EnvelopeSigner.fromSeed(keys.signSeed);
    return keyFingerprint(signer.signPublicKey);
  }

  Future<FolderSyncBindingRow> _binding(String folderId) async =>
      await (database.select(database.folderSyncBindings)
            ..where((row) => row.folderId.equals(folderId)))
          .getSingleOrNull() ??
      (throw const FolderSyncRefusal('This device is not set up in that folder.'));

  Future<MemberFile> _readMember(String folderId, String memberId) async {
    final path = '$opsDirectoryName/$memberId/$memberFileName';
    final length = await folder.length(path);
    if (length == null) {
      throw const FolderMetadataRefusal('This device has not finished writing its file yet.');
    }
    if (length > maxMetadataFileBytes) {
      throw const FolderMetadataRefusal('member.json is too large.');
    }
    final member = MemberFile.parse(
        await folder.read(path, offset: 0, maxBytes: maxMetadataFileBytes));
    if (member.folderId != folderId) {
      throw const FolderMetadataRefusal('This device belongs to a different folder.');
    }
    if (member.memberId != memberId) {
      throw const FolderMetadataRefusal('This device\'s file names a different device.');
    }
    return member;
  }
}
