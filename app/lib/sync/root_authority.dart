/// Root: the trust anchor every Member chains back to (ADR-0028).
///
/// Root is a **random** Ed25519 keypair, never derived from the passphrase
/// (review F1) — deriving it would make the passphrase the key rather than the
/// wrapper, and a passphrase change would then be a key rotation instead of a
/// re-wrap. It lives in exactly one place at rest: inside the recovery escrow
/// blob. A Device holds it only for the length of an enrolment ceremony or a
/// passphrase change, and drops it afterwards.
///
/// Root is not a Member and never authors an envelope. Its whole vocabulary is
/// two signatures: a registration certificate, and a recovery escrow record.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'control_payload.dart';
import 'envelope.dart';
import 'recovery_escrow.dart';

class RootAuthority {
  RootAuthority._(this._keyPair, this._secretKey, this.rootPk);

  /// A fresh Root. Random, always — see the library docstring.
  static Future<RootAuthority> generate({Random? random}) =>
      fromSecretKey(_randomBytes(random ?? Random.secure(), rootSecretKeyBytes));

  /// Re-open Root from the 32 secret bytes recovered out of an escrow blob.
  static Future<RootAuthority> fromSecretKey(Uint8List rootSecretKey) async {
    if (rootSecretKey.length != rootSecretKeyBytes) {
      throw ArgumentError('root secret key must be $rootSecretKeyBytes bytes');
    }
    final keyPair = await Ed25519().newKeyPairFromSeed(rootSecretKey);
    final publicKey = await keyPair.extractPublicKey();
    return RootAuthority._(
      keyPair,
      Uint8List.fromList(rootSecretKey),
      Uint8List.fromList(publicKey.bytes),
    );
  }

  final SimpleKeyPair _keyPair;
  Uint8List _secretKey;

  /// The 32 raw public bytes a Device pins on first successful unwrap.
  final Uint8List rootPk;

  /// The secret half, for escrowing it. Throws once [drop] has run.
  Uint8List get secretKey {
    if (_secretKey.isEmpty) {
      throw StateError('Root was dropped at the end of the ceremony');
    }
    return _secretKey;
  }

  Future<Uint8List> signCertificate(RegistrationCertificate certificate) async =>
      signCertificateBytes(certificate.encode());

  Future<Uint8List> signCertificateBytes(Uint8List certBytes) =>
      signDomainSeparated(_keyPair, registrationSigningInput(certBytes));

  Future<Uint8List> signEscrow(String workspaceId, int version, Uint8List blob) =>
      signDomainSeparated(_keyPair, escrowSigningInput(workspaceId, version, blob));

  /// Build and sign the record the escrow slot stores.
  Future<RecoveryEscrowRecord> escrowRecord({
    required String workspaceId,
    required int version,
    required Uint8List blob,
  }) async =>
      RecoveryEscrowRecord(
        version: version,
        blob: blob,
        rootSig: await signEscrow(workspaceId, version, blob),
        rootPk: rootPk,
      );

  /// End of ceremony: forget the secret bytes we can reach.
  ///
  /// Best-effort by necessity. Dart gives no way to guarantee a buffer is not
  /// still sitting in a copy the VM made — full at-rest and in-memory hardening
  /// is review F22 and is not claimed here. Overwriting what we *can* reach
  /// still shortens the window, and makes a use-after-drop a loud [StateError]
  /// rather than a quiet signature with a key that should be gone.
  void drop() {
    _secretKey.fillRange(0, _secretKey.length, 0);
    _secretKey = Uint8List(0);
  }
}

Uint8List _randomBytes(Random random, int length) =>
    Uint8List.fromList(List<int>.generate(length, (_) => random.nextInt(256)));
