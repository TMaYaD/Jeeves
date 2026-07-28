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

/// The storage policy a signing seed is held under, stated rather than inherited.
///
/// A Device's seeds *are* its Member identity, so two properties are named here
/// instead of left to the plugin's defaults:
///
/// - **Apple platforms: `first_unlock_this_device`.** The default is
///   `KeychainAccessibility.unlocked`, which migrates the item to a new device
///   through an encrypted backup — restoring a backup onto a second handset
///   would then produce two Devices signing as one Member, which is precisely
///   the fork the per-author chain refuses. `first_unlock_this_device` keeps a
///   relaunched Device the same Member and keeps the seed on the one device.
/// - **Android: `resetOnError: false`.** The default silently *deletes* the
///   entry when it cannot be decrypted, which would turn a Keystore hiccup into
///   a Device that quietly loses its identity and re-enrols as a stranger. A
///   loud read failure is the recoverable outcome. The cipher choice is left at
///   the plugin's default (AES-GCM data, RSA-OAEP key wrapping, Keystore
///   backed); `encryptedSharedPreferences` is deprecated and ignored from
///   plugin v10, so passing it would document a hardening that no longer exists.
const IOSOptions _seedIosOptions = IOSOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
);
const MacOsOptions _seedMacOsOptions = MacOsOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
);
const AndroidOptions _seedAndroidOptions = AndroidOptions(resetOnError: false);

/// The production store: Keychain on iOS/macOS, Keystore-backed on Android.
class SecureStorageDeviceKeyStore implements DeviceKeyStore {
  const SecureStorageDeviceKeyStore([
    this._storage = const FlutterSecureStorage(
      iOptions: _seedIosOptions,
      mOptions: _seedMacOsOptions,
      aOptions: _seedAndroidOptions,
    ),
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
