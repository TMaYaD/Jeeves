/// The device enrolment ceremony — the same seven steps for the first Device
/// and the Nth.
///
/// That sameness is the point of ADR-0028's design: there is no "pairing" mode
/// that needs a second device online, and no code path that only the first
/// device takes. The only difference is where Root comes from — generated, or
/// unwrapped out of the recovery escrow with the passphrase.
///
/// ```
/// 1. Obtain Root for the ceremony
///      first device: generate (random, never derived — F1) + a master wrap key,
///                    build the blob, sign it, PUT at version 1, pin root_pk
///      Nth device:   GET the escrow -> floor-check -> unwrap -> pin root_pk
/// 2. Persist the device keypairs (separate sign and KEX — F8/F19)
/// 3. POST /members under the User credential — a shell row, no authority
/// 4. Proof of possession -> the member-scoped transport
/// 5. Pull and apply the existing control log
/// 6. Author the MemberRegister as this device's op 1, naming the head of the
///    log it just applied, and post it
/// 7. Drop Root
/// ```
///
/// **Steps 5 and 6 are not interchangeable.** A device that registered before
/// pulling would emit an all-zero `prev_control_hash` into a populated chain,
/// and every honest client would quarantine it as a fork. The pull is what
/// makes the chain link truthful.
library;

import 'dart:math';
import 'dart:typed_data';

import 'control_payload.dart';
import 'device_key_store.dart';
import 'hlc.dart';
import 'passphrase_policy.dart';
import 'recovery_escrow.dart';
import 'root_authority.dart';
import 'sync_client.dart';
import 'sync_transport.dart';

/// What an enrolment produced.
class EnrolmentOutcome {
  const EnrolmentOutcome({
    required this.passphrase,
    required this.strength,
    required this.isFirstDevice,
    required this.escrowVersion,
    required this.rootPk,
  });

  /// The passphrase the user must keep. Present for a first-device enrolment
  /// (Jeeves generated it, and this is the only time it is knowable) and for a
  /// later one (it is what the user just typed).
  final String passphrase;
  final PassphraseStrength strength;

  /// True when this ceremony minted Root rather than recovering it.
  final bool isFirstDevice;
  final int escrowVersion;

  /// The Root this device pinned. The public half only — the secret is gone.
  final Uint8List rootPk;
}

/// Runs the ceremony. Pure logic: the screens are #553's.
class EnrolmentService {
  EnrolmentService({
    required this.client,
    required this.userTransport,
    required this.keyStore,
    required int Function() nowMs,
    this.passphrasePolicy = const PassphrasePolicy(),
    this.kdfParameters = Argon2idParameters.floor,
    this.kdfFloor = Argon2idParameters.floor,
    // Seeds Root, the master wrap key, the salt, the nonce and the generated
    // passphrase — see [_random]. Pass `Random.secure()` or nothing.
    Random? random,
  })  : _nowMs = nowMs,
        _random = random ?? Random.secure();

  final SyncClient client;
  final UserTransport userTransport;
  final DeviceKeyStore keyStore;
  final PassphrasePolicy passphrasePolicy;

  /// What a blob this device *writes* is wrapped under, and the floor every
  /// blob it reads or writes must clear.
  ///
  /// Two parameters rather than one so the harness can run reduced costs
  /// through the same floor-checking code path instead of around it: it lowers
  /// both, and production leaves both at [Argon2idParameters.floor].
  final Argon2idParameters kdfParameters;
  final Argon2idParameters kdfFloor;

  final int Function() _nowMs;

  /// The single source of randomness for the whole ceremony.
  ///
  /// **Every secret this class mints comes out of this one object**: the Root
  /// secret key, the master wrap key, the escrow blob's Argon2id salt and its
  /// XChaCha20 nonce, and — when one is not supplied — the diceware passphrase.
  /// Seed it deterministically and you have not weakened one of those, you have
  /// published all five at once, and the escrow they protect is the account.
  ///
  /// So callers pass `Random.secure()` or nothing at all (the constructor
  /// defaults to `Random.secure()`). The seam exists for the test harness,
  /// which needs reproducible devices; there is no production reason to use it,
  /// and a seeded `Random` reaching this constructor outside a test is a
  /// catastrophic bug rather than a weak-crypto one.
  final Random _random;

  /// Enrol the first Device of an account: mint Root and escrow it.
  ///
  /// [passphrase] defaults to a generated diceware phrase. A user-chosen one is
  /// accepted — the returned [EnrolmentOutcome.strength] carries the estimate
  /// and the warning a screen must show if it is weak.
  Future<EnrolmentOutcome> enrolFirstDevice({String? passphrase}) async {
    final chosen = passphrase ?? passphrasePolicy.generate(random: _random);
    final strength = passphrase == null
        ? passphrasePolicy.strengthOfGenerated()
        : passphrasePolicy.estimate(passphrase);

    final root = await RootAuthority.generate(random: _random);
    try {
      final blob = await wrapEscrowBlob(
        passphrase: chosen,
        secrets: EscrowedSecrets(
          rootSecretKey: root.secretKey,
          // Escrowed now, read by nothing until #554. Minting it here is what
          // keeps the blob shape constant, so a passphrase change stays a pure
          // re-wrap for ever.
          masterWrapKey: _randomBytes(masterWrapKeyBytes),
        ),
        parameters: kdfParameters,
        floor: kdfFloor,
        random: _random,
      );
      final record = await userTransport.putRecoveryEscrow(
        client.workspaceId,
        await root.escrowRecord(
          workspaceId: client.workspaceId,
          version: firstEscrowVersion,
          blob: blob,
        ),
      );
      await client.pinRoot(root.rootPk, record.version);
      await _registerThisDevice(root);
      return EnrolmentOutcome(
        passphrase: chosen,
        strength: strength,
        isFirstDevice: true,
        escrowVersion: record.version,
        rootPk: root.rootPk,
      );
    } finally {
      root.drop();
    }
  }

  /// Enrol a further Device with nothing but the passphrase.
  Future<EnrolmentOutcome> enrolWithPassphrase(String passphrase) async {
    final (record, root) = await _recoverRoot(passphrase);
    try {
      await client.pinRoot(root.rootPk, record.version);
      await _registerThisDevice(root);
      return EnrolmentOutcome(
        passphrase: passphrase,
        strength: passphrasePolicy.estimate(passphrase),
        isFirstDevice: false,
        escrowVersion: record.version,
        rootPk: root.rootPk,
      );
    } finally {
      root.drop();
    }
  }

  /// Re-wrap the escrow under a new passphrase at version + 1.
  ///
  /// Explicitly **not** a remediation for a compromised passphrase: whoever
  /// copied the old blob can still open it, and no version bump takes that
  /// back. It is a rotation of the wrapper, not of Root.
  Future<EnrolmentOutcome> changePassphrase({
    required String currentPassphrase,
    required String newPassphrase,
  }) async {
    final (record, root) = await _recoverRoot(currentPassphrase);
    try {
      final blob = await wrapEscrowBlob(
        passphrase: newPassphrase,
        secrets: EscrowedSecrets(
          rootSecretKey: root.secretKey,
          masterWrapKey: _randomBytes(masterWrapKeyBytes),
        ),
        parameters: kdfParameters,
        floor: kdfFloor,
        random: _random,
      );
      final written = await userTransport.putRecoveryEscrow(
        client.workspaceId,
        await root.escrowRecord(
          workspaceId: client.workspaceId,
          version: record.version + 1,
          blob: blob,
        ),
      );
      await client.pinRoot(root.rootPk, written.version);
      return EnrolmentOutcome(
        passphrase: newPassphrase,
        strength: passphrasePolicy.estimate(newPassphrase),
        isFirstDevice: false,
        escrowVersion: written.version,
        rootPk: root.rootPk,
      );
    } finally {
      root.drop();
    }
  }

  /// Fetch, check and unwrap the escrow — the alarm-not-prompt half of F12.
  Future<(RecoveryEscrowRecord, RootAuthority)> _recoverRoot(String passphrase) async {
    final record = await userTransport.fetchRecoveryEscrow(client.workspaceId);
    if (record == null) {
      throw const RecoveryEscrowException(
        RecoveryEscrowFailure.malformedBlob,
        'this account has no recovery escrow to enrol against',
      );
    }

    final pinned = await client.pinnedRootPk();
    if (pinned != null) {
      // A device holding a pin checks the signature *before* prompting, so a
      // substituted blob alarms rather than reading as a typo.
      await verifyEscrowRecordSignature(record, client.workspaceId, pinned);
    }
    if (record.version < await client.highestEscrowVersionSeen()) {
      throw RecoveryEscrowException(
        RecoveryEscrowFailure.versionRollback,
        'served escrow version ${record.version} is below the highest this '
        'device has seen',
      );
    }

    // Floor first: a below-floor blob is refused before any KDF work runs.
    readEscrowBlobParameters(record.blob, floor: kdfFloor);
    final secrets = await unwrapEscrowBlob(
      blob: record.blob,
      passphrase: passphrase,
      floor: kdfFloor,
    );
    final root = await RootAuthority.fromSecretKey(secrets.rootSecretKey);
    if (pinned == null) {
      // Trust on first use, against the passphrase and not the server. The
      // cross-check is retroactive but real: the record we just accepted must
      // be signed by the Root the passphrase produced.
      await verifyEscrowRecordSignature(record, client.workspaceId, root.rootPk);
    }
    return (record, root);
  }

  /// Steps 2 through 7 — everything after Root is in hand.
  Future<void> _registerThisDevice(RootAuthority root) async {
    final identity = client.identity;

    // 2. Persist the keypairs before anything can depend on them existing.
    await keyStore.write(
      client.workspaceId,
      StoredDeviceKeys(
        memberId: identity.memberId,
        signSeed: identity.signer.seed,
        kexSeed: identity.kexSeed,
      ),
    );

    // 3. A shell row: public keys and no authority whatsoever.
    await userTransport.registerMember(
      memberId: identity.memberId,
      signPk: identity.signPk,
      kexPk: identity.kexPk,
    );

    // 4. Prove possession of the signing key, and take the member credential.
    final nonce = await userTransport.requestMemberChallenge(identity.memberId);
    client.useMemberTransport(
      await userTransport.completeMemberChallenge(
        memberId: identity.memberId,
        nonce: nonce,
        signature: await identity.signTransportChallenge(nonce),
      ),
    );

    // 5. Apply the control log before claiming a place in it.
    await client.pull();

    // 6. Register, naming the head this device actually observed.
    final certificate = identity.certificateFor(
      workspaceId: client.workspaceId,
      registeredAtHlc: Hlc.forMember(identity.memberId, _nowMs()),
    );
    final certBytes = certificate.encode();
    await client.captureControl(
      ControlPayload(
        controlType: controlTypeMemberRegister,
        prevControlHash: await client.appliedControlHead(),
        certBytes: certBytes,
        rootSig: await root.signCertificateBytes(certBytes),
      ).encode(),
    );
    await client.flushOutbox();
    // 7. Root is dropped by the caller's `finally`, whatever happened here.
  }

  Uint8List _randomBytes(int length) =>
      Uint8List.fromList(List<int>.generate(length, (_) => _random.nextInt(256)));
}
