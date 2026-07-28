/// The device enrolment ceremony — one code path, branching on what the *log*
/// says rather than on which device this is.
///
/// There is no "pairing" mode that needs a second device online, and no step that
/// only the first device of an account takes. The only two differences are where
/// Root comes from — generated, or unwrapped out of the recovery escrow with the
/// passphrase — and whether the Workspace being enrolled into already has a
/// genesis. That second branch is decided by **pulling and looking**, which is
/// what makes it recoverable rather than positional.
///
/// ```
/// 1. Obtain Root for the ceremony
///      first device: generate (random, never derived — F1) + a master wrap key
///      Nth device:   GET the default escrow -> floor-check -> unwrap
/// 2. Pin root_pk, and write the escrow to BOTH slots — default first, then
///    user_preferences. Recovery always reads the default slot, so a crash
///    between the two PUTs leaves the recoverable one written.
/// 3. Persist the device keypairs (separate sign and KEX — F8/F19)
/// 4. POST /members under the User credential — a shell row, no authority
/// 5. Proof of possession -> the member-scoped transport
/// 6. Per Workspace, default first then user_preferences:
///      pull and apply the existing control log, then branch on what was seen
///        observed EMPTY     -> op 1 `workspace_genesis`, op 2 root-signed
///                             owner self-grant
///        observed NON-EMPTY -> op 1 `member_register`, op 2 root-signed
///                             owner self-grant
/// 7. Drop Root
/// ```
///
/// **Genesis authorship is log-state-conditioned, not device-ordinal-conditioned**
/// (ADR-0031): *any* device holding Root authors the genesis for a Workspace whose
/// control log it observed empty. A first-device rule would leave an
/// unrecoverable window — the prefs escrow PUT lands, the process dies before the
/// prefs genesis posts, and from then on every later device takes the "Nth" path
/// into a genesis-less Workspace and is fork-refused forever. Conditioning on the
/// log closes it: the next enrolling device observes the empty prefs log and
/// authors the genesis itself.
///
/// **The pull is not interchangeable with the claim.** A device that authored
/// before pulling would emit a fork-lie `prev_control_hash`, and every honest
/// client would quarantine it. The pull happens while this device holds a member
/// credential and *no Grant whatsoever*, which is exactly what the server's
/// member-GET rule exists to admit.
///
/// **Every Device gets an explicit root-signed owner Grant.** Roles are one
/// materialisation path — no implied grants, genesis included. Devices are owners
/// because the User acts through them, and the corollary is deliberate: revoking a
/// Device takes the passphrase, because only Root can revoke an owner Grant.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import 'control_payload.dart';
import 'device_key_store.dart';
import 'envelope.dart';
import 'hlc.dart';
import 'ids.dart';
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
    required this.workspaceClientFactory,
    required int Function() nowMs,
    this.passphrasePolicy = const PassphrasePolicy(),
    this.kdfParameters = Argon2idParameters.floor,
    this.kdfFloor = Argon2idParameters.floor,
    // Seeds Root, the master wrap key, the salt, the nonce and the generated
    // passphrase — see [_random]. Pass `Random.secure()` or nothing.
    Random? random,
  })  : _nowMs = nowMs,
        _random = random ?? Random.secure();

  /// The client for the **default** Workspace. The ceremony is per-User, so it
  /// reaches the second Workspace through [workspaceClientFactory].
  final SyncClient client;
  final UserTransport userTransport;
  final DeviceKeyStore keyStore;

  /// Builds (or returns) the client for another of this User's Workspaces.
  ///
  /// Required rather than optional: the ceremony covers two Workspaces, and a
  /// service that silently covered one would leave the preferences Workspace
  /// genesis-less — which is the state the log-state branch exists to recover
  /// from, not one worth creating on purpose.
  final Future<SyncClient> Function(String workspaceId) workspaceClientFactory;

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

  /// The wrapped blob this ceremony writes into **both** escrow slots.
  ///
  /// The same bytes under two signatures — `workspace_id` is inside the
  /// preimage — whether they were just generated (first device) or fetched from
  /// the default slot (any later device). Identical bytes is what makes the
  /// second slot a copy rather than a second secret to keep track of.
  Uint8List? _escrowBlob;

  /// Slots this ceremony already knows the record for.
  ///
  /// The default slot is always one of them — either just written or just
  /// fetched — and re-reading it would spend another of the escrow route's
  /// audited, rate-limited fetches for an answer already in hand.
  final Map<String, RecoveryEscrowRecord> _knownEscrowRecords = {};

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
      _escrowBlob = blob;
      // The default slot first, and pinned before anything else: recovery always
      // reads this slot, so a crash after it leaves the account recoverable. The
      // prefs slot is written by `_registerThisDevice`, strictly before any prefs
      // genesis is posted — the server resolves `root_pk` from the slot of the
      // Workspace being posted to, so posting into a slotless one is unverifiable.
      final record = await userTransport.putRecoveryEscrow(
        client.workspaceId,
        await root.escrowRecord(
          workspaceId: client.workspaceId,
          version: firstEscrowVersion,
          blob: blob,
        ),
      );
      _knownEscrowRecords[client.workspaceId] = record;
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
    // The bytes this ceremony will copy into any slot that is still empty.
    _escrowBlob = record.blob;
    _knownEscrowRecords[client.workspaceId] = record;
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

    // 2. Both escrow slots, in a pinned order. The default slot first, because
    //    recovery always reads that one: a crash between the two PUTs must leave
    //    the recoverable slot written rather than the other way round.
    //
    //    Two slots doubles the pre-first-write TOFU surface the escrow docstring
    //    describes (two first-writes instead of one, same trust model) and is
    //    accepted for the same reason the window was accepted at all. It is what
    //    keeps the server's control verification uniform per Workspace —
    //    `root_pk` is resolved from the slot of the Workspace being posted to —
    //    and it survives shared Workspaces without a shape change.
    for (final workspace in _workspaces) {
      await _writeEscrowSlot(root, workspace);
    }

    // 3. Persist the keypairs before anything can depend on them existing.
    await keyStore.write(
      client.workspaceId,
      StoredDeviceKeys(
        memberId: identity.memberId,
        signSeed: identity.signer.seed,
        kexSeed: identity.kexSeed,
      ),
    );

    // 4. A shell row: public keys and no authority whatsoever.
    await userTransport.registerMember(
      memberId: identity.memberId,
      signPk: identity.signPk,
      kexPk: identity.kexPk,
    );

    // 5. Prove possession of the signing key, and take the member credential.
    final nonce = await userTransport.requestMemberChallenge(identity.memberId);
    client.useMemberTransport(
      await userTransport.completeMemberChallenge(
        memberId: identity.memberId,
        nonce: nonce,
        signature: await identity.signTransportChallenge(nonce),
      ),
    );

    // 6. Per Workspace, default first: pull, look, then claim.
    for (final workspace in _workspaces) {
      await _claimPlaceIn(workspace, root);
    }
    // 7. Root is dropped by the caller's `finally`, whatever happened here.
  }

  /// The two Workspaces every enrolment covers, in the order it covers them.
  List<String> get _workspaces => derivableWorkspaceIds(client.userId);

  /// Write the slot if it is empty, and **pin Root for it either way**.
  ///
  /// The pin is per `(workspace, user)` because the escrow slot is: each Workspace
  /// resolves its own `root_pk`, so a device that pinned only one of them could
  /// not verify a control op in the other. Skipping the pin is what leaves the
  /// second Workspace's log unverifiable and its genesis re-authored for ever.
  Future<void> _writeEscrowSlot(RootAuthority root, String workspaceId) async {
    final scoped =
        workspaceId == client.workspaceId ? client : await workspaceClientFactory(workspaceId);
    final known = _knownEscrowRecords[workspaceId];
    var version = known?.version ?? firstEscrowVersion;
    if (known == null) {
      // The same blob under a second signature: `workspace_id` is inside the
      // preimage, so a record signed for one Workspace can never be replayed
      // into another.
      //
      // **Written blind, and a version conflict is the answer "already there".**
      // A slot that already holds a record is not this ceremony's to replace, and
      // asking first would spend one of the escrow *read* path's audited,
      // rate-limited fetches on a question the write itself answers.
      try {
        final written = await userTransport.putRecoveryEscrow(
          workspaceId,
          await root.escrowRecord(
            workspaceId: workspaceId,
            version: firstEscrowVersion,
            blob: _escrowBlob!,
          ),
        );
        version = written.version;
        _knownEscrowRecords[workspaceId] = written;
      } on SyncTransportException catch (refusal) {
        if (refusal.code != escrowVersionRegressionCode) rethrow;
        // Written by an earlier device, or by an earlier run of this ceremony
        // that crashed after the PUT. Either way the slot holds the same Root:
        // both slots carry one blob, written in lockstep.
        version = firstEscrowVersion;
      }
    }
    await scoped.pinRoot(root.rootPk, version);
  }

  /// Pull the Workspace's control log, then author the two ops it needs.
  ///
  /// The branch is on **what the log said**, not on which device this is. A
  /// Workspace whose control log is observed empty gets a genesis from whoever is
  /// holding Root; one that is not gets an ordinary registration.
  ///
  /// **Observing an empty log does not win the race, it only enters it.** Another
  /// Root-holder may found the Workspace between this pull and this POST, and the
  /// server answers the loser with `genesis_not_first`. That is not a failure to
  /// report: the loser drops its genesis, pulls the winner's, and takes the
  /// register path — which is the *other* branch of this same method, so losing
  /// costs one extra iteration and no extra code path.
  ///
  /// Two passes is the exact bound. A Workspace can be founded once, so a second
  /// pass observes a non-empty log and cannot be racing anything.
  Future<void> _claimPlaceIn(String workspaceId, RootAuthority root) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      if (await _claimOnce(workspaceId, root) != FlushOutcome.genesisSuperseded) return;
    }
    throw StateError(
      'lost the genesis race for $workspaceId twice, which cannot happen: a '
      'Workspace is founded once, so the second attempt observed a log that was '
      'empty after a genesis had already been refused into it',
    );
  }

  /// One pass of the claim. Returns what its flush concluded.
  Future<FlushOutcome> _claimOnce(String workspaceId, RootAuthority root) async {
    final scoped = client.workspaceId == workspaceId
        ? client
        : await workspaceClientFactory(workspaceId);

    // The pull is load-bearing, and it runs while this device holds a member
    // credential and no Grant: authoring first would emit a fork-lie chain link.
    await scoped.pull();
    final observedHead = await scoped.appliedControlHead();
    final observedEmpty = sameBytes(observedHead, zeroPrevControlHash);

    final Uint8List firstPayload;
    if (observedEmpty) {
      final genesis = GenesisCertificate(
        workspaceId: workspaceId,
        rootPk: root.rootPk,
        founder: scoped.identity.certificateFor(
          workspaceId: workspaceId,
          registeredAtHlc: Hlc.forMember(scoped.identity.memberId, _nowMs()),
        ).keys,
        createdAtHlc: Hlc.forMember(scoped.identity.memberId, _nowMs()),
      );
      final certBytes = genesis.encode();
      firstPayload = ControlPayload(
        controlType: controlTypeWorkspaceGenesis,
        prevControlHash: zeroPrevControlHash,
        certBytes: certBytes,
        signature: await root.signGenesisCertificateBytes(certBytes),
      ).encode();
    } else {
      final certificate = scoped.identity.certificateFor(
        workspaceId: workspaceId,
        registeredAtHlc: Hlc.forMember(scoped.identity.memberId, _nowMs()),
      );
      final certBytes = certificate.encode();
      firstPayload = ControlPayload(
        controlType: controlTypeMemberRegister,
        prevControlHash: observedHead,
        certBytes: certBytes,
        signature: await root.signCertificateBytes(certBytes),
      ).encode();
    }
    await scoped.captureControl(firstPayload);

    // The explicit owner Grant. Root-signed because an owner role may only be
    // minted by Root (ADR-0031) — which is also why revoking this Device later
    // takes the passphrase.
    final grant = GrantCertificate(
      workspaceId: workspaceId,
      grantId: _newGrantId(),
      memberId: scoped.identity.memberId,
      role: roleOwner,
      granter: granterRoot,
      grantedAtHlc: Hlc.forMember(scoped.identity.memberId, _nowMs()),
    );
    final grantBytes = grant.encode();
    await scoped.captureControl(
      ControlPayload(
        controlType: controlTypeGrant,
        prevControlHash: controlPayloadHash(firstPayload),
        certBytes: grantBytes,
        signature: await root.signGrantCertificateBytes(grantBytes),
        authority: granterRoot,
      ).encode(),
    );
    final flushed = await scoped.flushOutbox();
    if (flushed == FlushOutcome.genesisSuperseded) {
      // The genesis and the Grant chained to it are both gone from the queue and
      // the author chain is rewound; the caller's next pass pulls the winner's
      // genesis and registers into it.
      return flushed;
    }
    // And pull them back, so this device *applies* the two ops it just authored.
    // Control ops have no optimistic local path — they reduce to nothing, and the
    // directory, the grants view and the epoch floor are all filled by the receive
    // pipeline. Without this a freshly enrolled device would not know its own
    // authority until its next sync, which is a needlessly odd moment to leave it
    // in when the round-trip is already in hand.
    await scoped.pull();
    return flushed;
  }

  String _newGrantId() => const Uuid().v4();

  Uint8List _randomBytes(int length) =>
      Uint8List.fromList(List<int>.generate(length, (_) => _random.nextInt(256)));
}
