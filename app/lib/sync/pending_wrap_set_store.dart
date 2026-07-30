/// Where a prepared-but-not-yet-published epoch wrap set lives between the moment
/// a rotation commits to it and the moment its PUT lands.
///
/// A rotation publishes an epoch's wrap set in two steps that are not atomic:
/// `flushOutbox()` materialises the signed `rotate` on the server (every device's
/// epoch floor then rises to `toEpoch` on its next pull), and `publish` uploads the
/// wraps and remembers the key. A crash between the two leaves an epoch nobody holds
/// the key for and that cannot be re-minted — a second `prepare` draws fresh
/// entropy, so its digest can never match the one the `rotate` already committed to,
/// and `PUT /w/{w}/keywraps` refuses it as `keywrap_digest_mismatch`.
///
/// The escape is to keep the prepared [PendingWrapSet] durable, written **before**
/// the flush, so the exact bytes the `rotate` committed to survive the crash and the
/// PUT can be retried — from the next ceremony, the pull tail, or launch (see
/// `SyncClient.resumePendingWrapSets`). The record's *presence* is the retry
/// condition; it is removed only once the publish is confirmed.
///
/// **Same secure-storage tier as the epoch keys, never the sync database.** A wrap
/// set carries `workspaceKey` (`K_{w,epoch}`) in the clear — it is exactly the
/// sensitivity of the epoch-key map itself — so it is held under the same
/// platform-keychain posture as [WorkspaceKeyStore] and for the same reason: the
/// sync database's at-rest posture is review F22, explicitly unclaimed, and putting a
/// content key in the store that holds the ciphertext would make the encryption
/// decorative on a device whose file was copied.
///
/// A deliberate mirror of [WorkspaceKeyStore] and `DeviceKeyStore`: a production
/// implementation over the platform keychain and an in-memory one for the
/// multi-device harness, both real, no mock.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'key_wraps.dart' show MemberKeyWrap;

/// One epoch's prepared wrap set, as it travels from `prepare` to a resumed
/// `publish`. The serialisable twin of `EpochKeySet`, minus nothing it carries:
/// the member wraps, the escrow wrap, the digest the `rotate` committed to, and
/// `workspaceKey` — because the resume re-PUTs the set and then remembers the key,
/// which is the whole of what a live publish does.
class PendingWrapSet {
  const PendingWrapSet({
    required this.epoch,
    required this.workspaceKey,
    required this.memberWraps,
    required this.escrowWrap,
    required this.digest,
  });

  final int epoch;

  /// `K_{w,epoch}` — the content key the resume remembers once the PUT lands. In
  /// the clear here, which is why this record is keychain-tier.
  final Uint8List workspaceKey;

  final List<MemberKeyWrap> memberWraps;
  final Uint8List escrowWrap;

  /// The digest the signed `rotate` committed to. Kept so an epoch-0 resume can
  /// re-supply it in the PUT body; above epoch 0 the server reads it from the log.
  final Uint8List digest;

  Map<String, Object?> toJson() => {
        'epoch': epoch,
        'workspace_key': base64Encode(workspaceKey),
        'member_wraps': [
          for (final wrap in memberWraps)
            {
              'member_id': wrap.memberId,
              'kex_key_id': base64Encode(wrap.kexKeyId),
              'wrap': base64Encode(wrap.wrap),
            },
        ],
        'escrow_wrap': base64Encode(escrowWrap),
        'digest': base64Encode(digest),
      };

  static PendingWrapSet fromJson(Map<String, Object?> json) => PendingWrapSet(
        epoch: json['epoch']! as int,
        workspaceKey: base64Decode(json['workspace_key']! as String),
        memberWraps: [
          for (final wrap in (json['member_wraps']! as List).cast<Map<String, Object?>>())
            MemberKeyWrap(
              memberId: wrap['member_id']! as String,
              kexKeyId: base64Decode(wrap['kex_key_id']! as String),
              wrap: base64Decode(wrap['wrap']! as String),
            ),
        ],
        escrowWrap: base64Decode(json['escrow_wrap']! as String),
        digest: base64Decode(json['digest']! as String),
      );
}

abstract class PendingWrapSetStore {
  /// Every wrap set still awaiting publication for [workspaceId]. Empty when no
  /// rotation is mid-publish, which is the ordinary state.
  Future<List<PendingWrapSet>> read(String workspaceId);

  /// Make [set] durable for [workspaceId], keyed by its epoch. Overwrites any
  /// record already held for that epoch — a re-prepared rotation to the same epoch
  /// (only reachable when its `rotate` never materialised) is the newer truth.
  Future<void> put(String workspaceId, PendingWrapSet set);

  /// Drop the record for one epoch — the confirmation that its publish landed.
  Future<void> delete(String workspaceId, int epoch);

  /// Forget every pending set for this Workspace — the local half of being revoked,
  /// mirroring [WorkspaceKeyStore.clear].
  Future<void> clear(String workspaceId);
}

/// One store per instance, holding nothing beyond the process.
///
/// The harness's implementation: N simulated devices need N stores that cannot see
/// each other, and a phone that outlives a relaunch hands the fresh stack the same
/// instance — exactly as it does the epoch-key store, because the production store
/// is the platform keychain, which survives a process death.
class InMemoryPendingWrapSetStore extends PendingWrapSetStore {
  final Map<String, Map<int, PendingWrapSet>> _sets = {};

  /// A deep copy through the same JSON round-trip the secure-storage store makes
  /// on every read and write, so an in-memory record has the identical isolation:
  /// a caller that mutates a returned set's bytes cannot reach back into what is
  /// stored, and neither can whoever handed [put] its argument. The harness leans
  /// on this to behave exactly as the platform keychain — which only ever returns
  /// freshly deserialised bytes — would.
  static PendingWrapSet _snapshot(PendingWrapSet set) =>
      PendingWrapSet.fromJson(set.toJson());

  @override
  Future<List<PendingWrapSet>> read(String workspaceId) async =>
      [for (final set in (_sets[workspaceId] ?? const {}).values) _snapshot(set)];

  @override
  Future<void> put(String workspaceId, PendingWrapSet set) async {
    (_sets[workspaceId] ??= {})[set.epoch] = _snapshot(set);
  }

  @override
  Future<void> delete(String workspaceId, int epoch) async {
    _sets[workspaceId]?.remove(epoch);
  }

  @override
  Future<void> clear(String workspaceId) async {
    _sets.remove(workspaceId);
  }
}

/// The storage policy a pending wrap set is held under, stated rather than
/// inherited — the same two properties the epoch keys and device seeds are named
/// for: Apple `first_unlock_this_device` so the item never migrates to a second
/// handset through an encrypted backup, and Android `resetOnError: false` so a
/// Keystore hiccup is a loud read failure rather than a device that silently loses a
/// content key it can never re-mint.
const IOSOptions _pendingIosOptions = IOSOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
);
const MacOsOptions _pendingMacOsOptions = MacOsOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
);
const AndroidOptions _pendingAndroidOptions = AndroidOptions(resetOnError: false);

/// The production store: Keychain on iOS/macOS, Keystore-backed on Android — the
/// same tier as [WorkspaceKeyStore], so the wrap set and the epoch keys it becomes
/// share one at-rest posture.
class SecureStoragePendingWrapSetStore extends PendingWrapSetStore {
  SecureStoragePendingWrapSetStore([
    this._storage = const FlutterSecureStorage(
      iOptions: _pendingIosOptions,
      mOptions: _pendingMacOsOptions,
      aOptions: _pendingAndroidOptions,
    ),
  ]);

  final FlutterSecureStorage _storage;

  /// The tail of each Workspace's in-flight mutation, so [put]/[delete]/[clear]
  /// run one at a time per Workspace and their read-modify-write cannot interleave.
  /// A rotation's [put] and the pull tail's resuming [delete] reach the same key
  /// concurrently, and unserialised they would drop an epoch (both read the old
  /// map, both write their own) or undo a [clear] (a [put] writes back the record
  /// a [clear] just removed). Keyed by Workspace, so unrelated Workspaces never
  /// contend; the tail entry is dropped once nothing is queued behind it.
  final Map<String, Future<void>> _mutations = {};

  static String _key(String workspaceId) =>
      'jeeves/sync/pending_wrap_sets/$workspaceId';

  Future<T> _serialised<T>(String workspaceId, Future<T> Function() action) async {
    final prior = _mutations[workspaceId];
    final done = Completer<void>();
    _mutations[workspaceId] = done.future;
    try {
      if (prior != null) {
        try {
          await prior;
        } on Object {
          // The previous mutation's outcome is its own caller's to observe; we
          // only need it to have finished before we read-modify-write.
        }
      }
      return await action();
    } finally {
      done.complete();
      // Drop the entry when we are still the tail — nobody queued behind us — so
      // the map does not grow one dead future per mutation for ever.
      if (identical(_mutations[workspaceId], done.future)) {
        _mutations.remove(workspaceId);
      }
    }
  }

  Future<Map<int, PendingWrapSet>> _read(String workspaceId) async {
    final raw = await _storage.read(key: _key(workspaceId));
    if (raw == null) return {};
    final decoded = jsonDecode(raw) as Map<String, Object?>;
    return {
      for (final entry in decoded.entries)
        int.parse(entry.key):
            PendingWrapSet.fromJson(entry.value! as Map<String, Object?>),
    };
  }

  Future<void> _write(String workspaceId, Map<int, PendingWrapSet> byEpoch) {
    if (byEpoch.isEmpty) return _storage.delete(key: _key(workspaceId));
    return _storage.write(
      key: _key(workspaceId),
      value: jsonEncode({
        for (final entry in byEpoch.entries) '${entry.key}': entry.value.toJson(),
      }),
    );
  }

  @override
  Future<List<PendingWrapSet>> read(String workspaceId) async =>
      (await _read(workspaceId)).values.toList();

  @override
  Future<void> put(String workspaceId, PendingWrapSet set) =>
      _serialised(workspaceId, () async {
        final byEpoch = await _read(workspaceId);
        byEpoch[set.epoch] = set;
        await _write(workspaceId, byEpoch);
      });

  @override
  Future<void> delete(String workspaceId, int epoch) =>
      _serialised(workspaceId, () async {
        final byEpoch = await _read(workspaceId);
        if (byEpoch.remove(epoch) == null) return;
        await _write(workspaceId, byEpoch);
      });

  @override
  Future<void> clear(String workspaceId) =>
      _serialised(workspaceId, () => _storage.delete(key: _key(workspaceId)));
}
