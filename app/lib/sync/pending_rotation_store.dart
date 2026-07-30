/// Where a rotation's prepared wrap set waits between the moment it is authored
/// and the moment its `publish` is confirmed.
///
/// A `toEpoch -> EpochKeySet` map, one map per Workspace. A deliberate mirror of
/// [WorkspaceKeyStore]: a production implementation over the platform keychain and
/// an in-memory one for the multi-device harness, both real, no mock.
///
/// **Why it exists.** `WorkspaceKeyCeremony.publish` uploads the wrap set and only
/// then remembers the key locally (`key_ceremony.dart`), so a failure of the PUT
/// after the `rotate` has already been flushed strands the new epoch: the server
/// has raised every device's floor, the digest is committed to in a signed op, and
/// nobody — not even the rotating device — holds `K_{w,toEpoch}`. It is
/// unreconstructable, because a second `prepare` draws fresh entropy and cannot
/// reproduce the committed digest. The prepared [EpochKeySet] is the only object
/// that satisfies it, so it must survive the crash. This store is where it lives
/// until `publish` succeeds; [EnrolmentService.resumePendingRotations] re-publishes
/// it and then deletes the record.
///
/// **Same secure-storage tier as the epoch keys, never the sync database.** A
/// pending record carries `workspaceKey` in the clear — it is the same sensitivity
/// as the epoch key it will become — and the sync database's at-rest posture is
/// review F22, explicitly unclaimed (`workspace_key_store.dart`). Putting it in the
/// store that holds the ciphertext would make the encryption decorative on a device
/// whose file was copied, so this reuses the identical keychain options
/// [WorkspaceKeyStore]'s production store is pinned under.
///
/// **A map, not a single slot**, so a device is never forced to clobber one pending
/// epoch to record another; in practice at most one is ever live. The per-Workspace
/// future-chain discipline is copied from [WorkspaceKeyStore] so a resume-triggered
/// read-modify-write cannot interleave with a ceremony's write on the shared record.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'envelope.dart' show authorKeyIdBytes, workspaceKeyBytes;
import 'key_ceremony.dart';
import 'key_wraps.dart';

/// The `toEpoch -> set` map, as stored.
typedef PendingRotationsByEpoch = Map<int, EpochKeySet>;

abstract class PendingRotationStore {
  /// Every pending rotation this device holds for [workspaceId], read on the same
  /// per-Workspace mutation chain [put] and [remove] run on. Empty when none is in
  /// flight, which is the ordinary steady state.
  ///
  /// Chained because a corrupt record makes [readRaw] *write* (its `clearRaw`
  /// self-heal): an external `read` — `resumePendingRotations` calls this one
  /// directly — must not let that deferred delete land after a concurrent `put`'s
  /// write and clobber the set it just persisted. [put]/[remove] call [readRaw]
  /// instead, because they already run inside [_serialised] and would deadlock on
  /// this one.
  Future<PendingRotationsByEpoch> read(String workspaceId) =>
      _serialised(workspaceId, () => readRaw(workspaceId));

  /// [read] off the mutation chain — the storage read itself, including the
  /// per-record corruption self-heal. Only ever called from inside a [_serialised]
  /// body ([read], [put], [remove]); never reach for it from outside one.
  Future<PendingRotationsByEpoch> readRaw(String workspaceId);

  /// Replace the whole map. Callers that add one epoch go through [put]; callers
  /// that drop one go through [remove].
  Future<void> write(String workspaceId, PendingRotationsByEpoch setsByEpoch);

  /// Forget every pending rotation for this Workspace, straight to storage and
  /// off the mutation chain. Callers go through [clear], which runs this on the
  /// same per-Workspace chain [put] and [remove] use; [readRaw] calls it directly on
  /// the corruption path, where it is already inside a chained body.
  Future<void> clearRaw(String workspaceId);

  /// The tail of the last mutation per Workspace, so read-modify-writes chain.
  ///
  /// A `put` racing a `remove` on one secure-storage record (a resume overlapping a
  /// ceremony on the shared store) must never interleave — the same future-chain
  /// discipline [WorkspaceKeyStore] uses.
  final Map<String, Future<void>> _mutationTail = {};

  Future<T> _serialised<T>(String workspaceId, Future<T> Function() body) {
    final previous = _mutationTail[workspaceId] ?? Future<void>.value();
    final next = previous.then((_) => body());
    _mutationTail[workspaceId] = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  /// Record one prepared set, keyed by its own [EpochKeySet.epoch]. Overwriting an
  /// identical epoch is the idempotent re-run: a ceremony that persists, crashes
  /// before authoring, and is re-run draws a fresh set for the same `toEpoch`, and
  /// the newer one is the only one that could be published anyway.
  Future<void> put(String workspaceId, EpochKeySet set) =>
      _serialised(workspaceId, () async {
        final held = await readRaw(workspaceId);
        await write(workspaceId, {...held, set.epoch: set});
      });

  /// Drop one epoch's pending set — what `publish` succeeding calls.
  Future<void> remove(String workspaceId, int epoch) =>
      _serialised(workspaceId, () async {
        final held = await readRaw(workspaceId);
        if (!held.containsKey(epoch)) return;
        await write(workspaceId, {...held}..remove(epoch));
      });

  /// Forget every pending rotation for this Workspace, on the same per-Workspace
  /// mutation chain [put] and [remove] run on — so a clear cannot land between
  /// another mutation's `read` and its `write` and be silently undone.
  Future<void> clear(String workspaceId) =>
      _serialised(workspaceId, () => clearRaw(workspaceId));
}

/// One store per instance, holding nothing beyond the process.
///
/// The harness's implementation: N simulated devices need N stores that cannot see
/// each other, which is what N instances of this gives.
class InMemoryPendingRotationStore extends PendingRotationStore {
  final Map<String, PendingRotationsByEpoch> _sets = {};

  @override
  Future<PendingRotationsByEpoch> readRaw(String workspaceId) async =>
      {...?_sets[workspaceId]};

  @override
  Future<void> write(String workspaceId, PendingRotationsByEpoch setsByEpoch) async {
    _sets[workspaceId] = {...setsByEpoch};
  }

  @override
  Future<void> clearRaw(String workspaceId) async {
    _sets.remove(workspaceId);
  }
}

/// The storage policy a pending set is held under, stated rather than inherited.
///
/// The same two properties the epoch keys are pinned under in
/// `workspace_key_store.dart` — Apple `first_unlock_this_device` so the item never
/// migrates to a second handset through an encrypted backup, and Android
/// `resetOnError: false` so a Keystore hiccup is a loud read failure rather than a
/// device that silently loses the set it must publish.
const IOSOptions _pendingRotationIosOptions = IOSOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
);
const MacOsOptions _pendingRotationMacOsOptions = MacOsOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
);
const AndroidOptions _pendingRotationAndroidOptions =
    AndroidOptions(resetOnError: false);

/// The production store: Keychain on iOS/macOS, Keystore-backed on Android.
class SecureStoragePendingRotationStore extends PendingRotationStore {
  SecureStoragePendingRotationStore([
    this._storage = const FlutterSecureStorage(
      iOptions: _pendingRotationIosOptions,
      mOptions: _pendingRotationMacOsOptions,
      aOptions: _pendingRotationAndroidOptions,
    ),
  ]);

  final FlutterSecureStorage _storage;

  static String _key(String workspaceId) =>
      'jeeves/sync/pending_rotations/$workspaceId';

  @override
  Future<PendingRotationsByEpoch> readRaw(String workspaceId) async {
    final raw = await _storage.read(key: _key(workspaceId));
    if (raw == null) return {};
    // A corrupt record is unpublishable, and if it threw on every read it would
    // also be unremovable — wedging `resumePendingRotations` and every later
    // ceremony that resumes first, for good. So corruption self-discards here per
    // record: a set that never round-trips materialised nothing, and nothing is
    // stranded by dropping it. `clearRaw` (not `clear`) because this always runs
    // inside a `_serialised` body (`read`/`put`/`remove`), where the serialised
    // `clear` would deadlock — and being on that chain is what makes the delete safe.
    final Map<String, Object?> decoded;
    try {
      decoded = jsonDecode(raw) as Map<String, Object?>;
    } on Object {
      await clearRaw(workspaceId);
      return {};
    }
    final sets = <int, EpochKeySet>{};
    for (final entry in decoded.entries) {
      try {
        sets[int.parse(entry.key)] =
            _decodeEpochKeySet(entry.value! as Map<String, Object?>);
      } on Object {
        // One bad epoch is skipped, not fatal: the other Workspaces' — and this
        // Workspace's other epochs' — resumes must not be stranded by it. Left on
        // disk (inert, always skipped) rather than rewriting from a read.
        continue;
      }
    }
    return sets;
  }

  @override
  Future<void> write(String workspaceId, PendingRotationsByEpoch setsByEpoch) =>
      _storage.write(
        key: _key(workspaceId),
        value: jsonEncode({
          for (final entry in setsByEpoch.entries)
            '${entry.key}': _encodeEpochKeySet(entry.value),
        }),
      );

  @override
  Future<void> clearRaw(String workspaceId) =>
      _storage.delete(key: _key(workspaceId));
}

/// The on-disk shape of one [EpochKeySet].
///
/// A free function, and public, so the golden round-trip test can pin the codec
/// without reaching through a store. The set must reconstruct byte-for-byte: the
/// resumed `publish` re-PUTs it, and the server accepts a byte-identical replay as
/// an acknowledgement but refuses a set that hashes to a different digest, so an
/// inexact round-trip would turn a resume into `keywrap_digest_mismatch`.
Map<String, Object?> encodePendingEpochKeySet(EpochKeySet set) =>
    _encodeEpochKeySet(set);

/// The inverse of [encodePendingEpochKeySet].
EpochKeySet decodePendingEpochKeySet(Map<String, Object?> json) =>
    _decodeEpochKeySet(json);

Map<String, Object?> _encodeEpochKeySet(EpochKeySet set) => {
      'epoch': set.epoch,
      'workspace_key': base64Encode(set.workspaceKey),
      'member_wraps': [
        for (final wrap in set.memberWraps)
          {
            'member_id': wrap.memberId,
            'kex_key_id': base64Encode(wrap.kexKeyId),
            'wrap': base64Encode(wrap.wrap),
          },
      ],
      'escrow_wrap': base64Encode(set.escrowWrap),
      'digest': base64Encode(set.digest),
    };

EpochKeySet _decodeEpochKeySet(Map<String, Object?> json) {
  final memberWraps = [
    for (final entry in json['member_wraps']! as List)
      _decodeMemberWrap(entry as Map<String, Object?>),
  ];
  return EpochKeySet(
    epoch: json['epoch']! as int,
    workspaceKey: _bytes(json['workspace_key']! as String, workspaceKeyBytes,
        'workspace_key'),
    memberWraps: memberWraps,
    escrowWrap:
        _bytes(json['escrow_wrap']! as String, epochKeyEscrowWrapBytes, 'escrow_wrap'),
    digest: _bytes(json['digest']! as String, keyWrapDigestBytes, 'digest'),
  );
}

MemberKeyWrap _decodeMemberWrap(Map<String, Object?> json) => MemberKeyWrap(
      memberId: json['member_id']! as String,
      kexKeyId: _bytes(json['kex_key_id']! as String, authorKeyIdBytes, 'kex_key_id'),
      wrap: _bytes(json['wrap']! as String, keyWrapBytes, 'wrap'),
    );

/// Decode and length-check in one place: a stored set of the wrong width is
/// corruption, and a corrupt pending record must fail loudly here rather than be
/// PUT and refused with the opaque `keywrap_digest_mismatch`.
Uint8List _bytes(String encoded, int expectedLength, String field) {
  final decoded = base64Decode(encoded);
  if (decoded.length != expectedLength) {
    throw FormatException(
      'pending-rotation $field is $expectedLength bytes, got ${decoded.length}',
    );
  }
  return decoded;
}
