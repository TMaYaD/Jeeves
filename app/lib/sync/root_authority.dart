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

  /// Null once [drop] has run — which is what makes a use-after-drop a loud
  /// [StateError] rather than a valid Root signature made after the ceremony.
  SimpleKeyPair? _keyPair;
  Uint8List _secretKey;

  /// The 32 raw public bytes a Device pins on first successful unwrap.
  final Uint8List rootPk;

  /// The secret half, for escrowing it. Throws once [drop] has run.
  Uint8List get secretKey {
    if (_secretKey.isEmpty) _refuseDropped();
    return _secretKey;
  }

  /// The keypair every signing path goes through, or a [StateError].
  ///
  /// Root's whole contract is that it exists for the length of one ceremony, so
  /// *every* signature has to be gated on the same liveness check rather than
  /// only the paths that happen to touch [secretKey].
  SimpleKeyPair get _liveKeyPair => _keyPair ?? _refuseDropped();

  Never _refuseDropped() =>
      throw StateError('Root was dropped at the end of the ceremony');

  Future<Uint8List> signCertificate(RegistrationCertificate certificate) async =>
      signCertificateBytes(certificate.encode());

  Future<Uint8List> signCertificateBytes(Uint8List certBytes) =>
      signDomainSeparated(_liveKeyPair, registrationSigningInput(certBytes));

  /// Sign a Workspace genesis certificate.
  ///
  /// Its own domain, like every other use of this key: a signature made over a
  /// registration must never verify over a genesis, or a captured registration
  /// could be replayed as the founding of a Workspace (F7).
  Future<Uint8List> signGenesisCertificateBytes(Uint8List certBytes) =>
      signDomainSeparated(_liveKeyPair, genesisSigningInput(certBytes));

  /// Sign a Grant certificate as Root — the only authority that may mint an
  /// `owner` role (ADR-0031).
  Future<Uint8List> signGrantCertificateBytes(Uint8List certBytes) =>
      signDomainSeparated(_liveKeyPair, grantSigningInput(certBytes));

  /// Sign a Revoke certificate as Root — the only authority that may revoke an
  /// `owner` Grant, which is why removing a Device takes the passphrase.
  Future<Uint8List> signRevokeCertificateBytes(Uint8List certBytes) =>
      signDomainSeparated(_liveKeyPair, revokeSigningInput(certBytes));

  Future<Uint8List> signEscrow(String workspaceId, int version, Uint8List blob) =>
      signDomainSeparated(_liveKeyPair, escrowSigningInput(workspaceId, version, blob));

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

  /// End of ceremony: forget the secret bytes we can reach, and stop signing.
  ///
  /// Two halves, and both are needed. Zeroing [secretKey] is best-effort by
  /// necessity — Dart gives no way to guarantee a buffer is not still sitting in
  /// a copy the VM made, and full at-rest and in-memory hardening is review F22,
  /// not claimed here. Releasing the keypair is not best-effort: it is what
  /// makes every signing path above throw a [StateError] afterwards instead of
  /// quietly producing a valid Root signature once the ceremony is over.
  void drop() {
    _secretKey.fillRange(0, _secretKey.length, 0);
    _secretKey = Uint8List(0);
    _keyPair = null;
  }
}

Uint8List _randomBytes(Random random, int length) =>
    Uint8List.fromList(List<int>.generate(length, (_) => random.nextInt(256)));
