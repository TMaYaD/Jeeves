/// Where a Device's private keys live between launches.
///
/// A seam, not an abstraction for its own sake: the production implementation
/// needs a platform keychain and therefore a platform, and the multi-device
/// harness needs N independent stores in one process. Both are real
/// implementations of the same contract — there is no mock here.
///
/// Scope note: this stores the *seeds*, so a relaunched Device is the same
/// Member. Full at-rest hardening of the sync database itself (SQLite
/// encryption) is review F22 and is **not** claimed by this slice.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The 32-byte seeds behind a Device's two keypairs, plus the id they belong to.
class StoredDeviceKeys {
  const StoredDeviceKeys({
    required this.memberId,
    required this.signSeed,
    required this.kexSeed,
  });

  final String memberId;
  final Uint8List signSeed;
  final Uint8List kexSeed;

  Map<String, Object?> toJson() => {
        'member_id': memberId,
        'sign_seed': base64Encode(signSeed),
        'kex_seed': base64Encode(kexSeed),
      };

  static StoredDeviceKeys fromJson(Map<String, Object?> json) => StoredDeviceKeys(
        memberId: json['member_id']! as String,
        signSeed: base64Decode(json['sign_seed']! as String),
        kexSeed: base64Decode(json['kex_seed']! as String),
      );
}

abstract class DeviceKeyStore {
  Future<StoredDeviceKeys?> read(String workspaceId);

  Future<void> write(String workspaceId, StoredDeviceKeys keys);

  /// Forget this Device's keys — the local half of being revoked.
  Future<void> clear(String workspaceId);
}

/// One store per instance, holding nothing beyond the process.
///
/// The harness's implementation: N simulated devices need N stores that cannot
/// see each other, which is exactly what N instances of this gives.
class InMemoryDeviceKeyStore implements DeviceKeyStore {
  final Map<String, StoredDeviceKeys> _keys = {};

  @override
  Future<StoredDeviceKeys?> read(String workspaceId) async => _keys[workspaceId];

  @override
  Future<void> write(String workspaceId, StoredDeviceKeys keys) async {
    _keys[workspaceId] = keys;
  }

  @override
  Future<void> clear(String workspaceId) async {
    _keys.remove(workspaceId);
  }
}

/// The production store: Keychain on iOS/macOS, Keystore-backed on Android.
class SecureStorageDeviceKeyStore implements DeviceKeyStore {
  const SecureStorageDeviceKeyStore([
    this._storage = const FlutterSecureStorage(),
  ]);

  final FlutterSecureStorage _storage;

  static String _key(String workspaceId) => 'jeeves/sync/device_keys/$workspaceId';

  @override
  Future<StoredDeviceKeys?> read(String workspaceId) async {
    final raw = await _storage.read(key: _key(workspaceId));
    if (raw == null) return null;
    return StoredDeviceKeys.fromJson(jsonDecode(raw) as Map<String, Object?>);
  }

  @override
  Future<void> write(String workspaceId, StoredDeviceKeys keys) => _storage.write(
        key: _key(workspaceId),
        value: jsonEncode(keys.toJson()),
      );

  @override
  Future<void> clear(String workspaceId) => _storage.delete(key: _key(workspaceId));
}
