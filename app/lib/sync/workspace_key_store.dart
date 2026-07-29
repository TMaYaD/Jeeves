/// Where a Workspace's content keys live between launches.
///
/// The `epoch -> K_{w,epoch}` map, one map per Workspace. A deliberate mirror of
/// `DeviceKeyStore`: a production implementation over the platform keychain and an
/// in-memory one for the multi-device harness, both real, no mock.
///
/// **Not a drift table.** A Workspace content key is the same sensitivity tier as
/// the identity seeds — it opens every content op the Workspace ever carried — and
/// the sync database's at-rest posture is review F22, explicitly unclaimed. Putting
/// the keys in the store that holds the ciphertext would make the encryption
/// decorative on a device whose file was copied.
///
/// **Not an extension of `StoredDeviceKeys` either.** Identity seeds and Workspace
/// keys rotate on different drivers — a key rotation mints an epoch and touches no
/// seed; a re-enrolment mints seeds and touches no epoch — and that JSON is a
/// persisted format whose shape is a compatibility surface.
///
/// **Every epoch is kept for ever.** Soft-delete retention means content authored
/// at any past epoch may still have to be read, so a key is never dropped as a new
/// one arrives; [WorkspaceKeyStore.clear] exists for the whole-Workspace case (the
/// local half of being revoked), not for pruning history.
///
/// The two derived operations are concrete on the abstract class, and the
/// implementations `extend` rather than `implement` it: "remembering an epoch
/// refuses to overwrite a *different* key for it" is a property of the contract, not
/// something each store gets to decide.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'envelope.dart' show workspaceKeyBytes;

/// The `epoch -> key` map, as stored.
typedef WorkspaceEpochKeys = Map<int, Uint8List>;

abstract class WorkspaceKeyStore {
  /// Every epoch key this device holds for [workspaceId]. Empty for a Workspace
  /// that has never been keyed, which is exactly a `plaintext_v1` Workspace.
  Future<WorkspaceEpochKeys> read(String workspaceId);

  /// Replace the whole map. Callers that add one epoch go through [remember].
  Future<void> write(String workspaceId, WorkspaceEpochKeys keysByEpoch);

  /// Forget every epoch key for this Workspace — the local half of being revoked.
  Future<void> clear(String workspaceId);

  /// Add one epoch's key, keeping every epoch already held.
  ///
  /// Read-modify-write rather than a keyed insert, because the production store is
  /// a single secure-storage entry per Workspace: the map *is* the record. The
  /// ceremonies that call it are serialised by their own awaits.
  Future<void> remember(String workspaceId, int epoch, Uint8List key) async {
    if (key.length != workspaceKeyBytes) {
      throw ArgumentError(
        'a workspace key is $workspaceKeyBytes bytes, got ${key.length}',
      );
    }
    final held = await read(workspaceId);
    final existing = held[epoch];
    if (existing != null) {
      // Two different keys for one epoch is not a state to overwrite silently:
      // whichever is wrong, one of them cannot open the ops already reduced under
      // the other. An identical re-remember is the idempotent ceremony retry.
      if (!_sameBytes(existing, key)) {
        throw StateError(
          'this device already holds a different key for epoch $epoch of '
          '$workspaceId',
        );
      }
      return;
    }
    await write(workspaceId, {...held, epoch: key});
  }

  /// The key for one epoch, or null when this device holds none.
  ///
  /// Null is the fail-closed answer the receive path turns into
  /// `missing_epoch_key`: a healable delivery gap, never an assumption that the op
  /// must have been plaintext.
  Future<Uint8List?> keyFor(String workspaceId, int epoch) async =>
      (await read(workspaceId))[epoch];

  /// The highest epoch this device holds a key for, or null for none.
  Future<int?> highestEpochHeld(String workspaceId) async {
    final held = await read(workspaceId);
    if (held.isEmpty) return null;
    return held.keys.reduce((a, b) => a > b ? a : b);
  }
}

/// One store per instance, holding nothing beyond the process.
///
/// The harness's implementation: N simulated devices need N stores that cannot see
/// each other, which is what N instances of this gives.
class InMemoryWorkspaceKeyStore extends WorkspaceKeyStore {
  final Map<String, WorkspaceEpochKeys> _keys = {};

  @override
  Future<WorkspaceEpochKeys> read(String workspaceId) async =>
      {...?_keys[workspaceId]};

  @override
  Future<void> write(String workspaceId, WorkspaceEpochKeys keysByEpoch) async {
    _keys[workspaceId] = {...keysByEpoch};
  }

  @override
  Future<void> clear(String workspaceId) async {
    _keys.remove(workspaceId);
  }
}

/// The storage policy an epoch key is held under, stated rather than inherited.
///
/// The same two properties the device seeds are named for in `device_key_store.dart`
/// — Apple `first_unlock_this_device` so the item never migrates to a second
/// handset through an encrypted backup, and Android `resetOnError: false` so a
/// Keystore hiccup is a loud read failure rather than a device that silently loses
/// the keys to its own history.
const IOSOptions _epochKeyIosOptions = IOSOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
);
const MacOsOptions _epochKeyMacOsOptions = MacOsOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
);
const AndroidOptions _epochKeyAndroidOptions = AndroidOptions(resetOnError: false);

/// The production store: Keychain on iOS/macOS, Keystore-backed on Android.
class SecureStorageWorkspaceKeyStore extends WorkspaceKeyStore {
  SecureStorageWorkspaceKeyStore([
    this._storage = const FlutterSecureStorage(
      iOptions: _epochKeyIosOptions,
      mOptions: _epochKeyMacOsOptions,
      aOptions: _epochKeyAndroidOptions,
    ),
  ]);

  final FlutterSecureStorage _storage;

  static String _key(String workspaceId) =>
      'jeeves/sync/workspace_keys/$workspaceId';

  @override
  Future<WorkspaceEpochKeys> read(String workspaceId) async {
    final raw = await _storage.read(key: _key(workspaceId));
    if (raw == null) return {};
    final decoded = jsonDecode(raw) as Map<String, Object?>;
    return {
      for (final entry in decoded.entries)
        int.parse(entry.key): base64Decode(entry.value! as String),
    };
  }

  @override
  Future<void> write(String workspaceId, WorkspaceEpochKeys keysByEpoch) =>
      _storage.write(
        key: _key(workspaceId),
        value: jsonEncode({
          for (final entry in keysByEpoch.entries)
            '${entry.key}': base64Encode(entry.value),
        }),
      );

  @override
  Future<void> clear(String workspaceId) => _storage.delete(key: _key(workspaceId));
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}
