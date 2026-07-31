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
import 'key_ceremony.dart';
import 'passphrase_policy.dart';
import 'pending_rotation_store.dart';
import 'recovery_escrow.dart';
import 'root_authority.dart';
import 'rotation_resume_refusal.dart';
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
    required this.pendingRotations,
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

  /// Where a prepared wrap set is made durable before its `rotate` is authored, so
  /// a crash between the flush and the `publish` is resumable rather than a
  /// permanently unpublishable epoch. Same secure-storage tier as the epoch keys.
  final PendingRotationStore pendingRotations;

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
  /// [encryptFromGenesis] keys every Workspace this ceremony founds at epoch 0, so
  /// it is encrypted from its first content op.
  ///
  /// **Off by default, and deliberately.** Landing #554 must change nothing about
  /// what an existing deployment emits — encryption turns on per Workspace via the
  /// explicit owner-run [turnOnEncryption] ceremony, never by a deploy — and the
  /// plaintext cutover in #553 depends on a freshly enrolled Workspace being
  /// byte-inspectable while it is verified. Flipping the default is the cutover's
  /// decision to make once that verification is done, and it is one word here.
  Future<EnrolmentOutcome> enrolFirstDevice({
    String? passphrase,
    bool encryptFromGenesis = false,
  }) async {
    final chosen = passphrase ?? passphrasePolicy.generate(random: _random);
    final strength = passphrase == null
        ? passphrasePolicy.strengthOfGenerated()
        : passphrasePolicy.estimate(passphrase);

    final root = await RootAuthority.generate(random: _random);
    final masterWrapKey = _randomBytes(masterWrapKeyBytes);
    try {
      final blob = await wrapEscrowBlob(
        passphrase: chosen,
        secrets: EscrowedSecrets(
          rootSecretKey: root.secretKey,
          // Minting it here is what keeps the blob shape constant, so a passphrase
          // change stays a pure re-wrap for ever. Its first reader is the epoch-key
          // escrow wrap below.
          masterWrapKey: masterWrapKey,
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
      await _registerThisDevice(
        root,
        masterWrapKey: masterWrapKey,
        encryptFromGenesis: encryptFromGenesis,
      );
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
  ///
  /// [encryptFromGenesis] only bites on a Workspace this ceremony *founds* — the
  /// log-state branch means a later device can be the one that founds the
  /// preferences Workspace. A Workspace that already has a genesis is joined, and
  /// whether it is encrypted is a fact about it rather than a choice made here.
  Future<EnrolmentOutcome> enrolWithPassphrase(
    String passphrase, {
    bool encryptFromGenesis = false,
  }) async {
    final (record, root, secrets) = await _recoverRoot(passphrase);
    try {
      await client.pinRoot(root.rootPk, record.version);
      await _registerThisDevice(
        root,
        masterWrapKey: secrets.masterWrapKey,
        encryptFromGenesis: encryptFromGenesis,
      );
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
  ///
  /// **Both escrowed secrets survive the rotation.** The new blob carries the
  /// master wrap key that came out of the old one rather than a fresh draw:
  /// minting a new one here would orphan every KeyWrap made under the previous
  /// key the moment #554 starts wrapping under it, and a passphrase change is a
  /// re-wrap of the wrapper, not a key rotation.
  Future<EnrolmentOutcome> changePassphrase({
    required String currentPassphrase,
    required String newPassphrase,
  }) async {
    final (record, root, secrets) = await _recoverRoot(currentPassphrase);
    try {
      final blob = await wrapEscrowBlob(
        passphrase: newPassphrase,
        secrets: EscrowedSecrets(
          rootSecretKey: root.secretKey,
          masterWrapKey: secrets.masterWrapKey,
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
  ///
  /// Returns the secrets as well as Root: [changePassphrase] re-wraps the
  /// *recovered* master wrap key, so discarding it here is what would silently
  /// rotate it.
  Future<(RecoveryEscrowRecord, RootAuthority, EscrowedSecrets)> _recoverRoot(
    String passphrase,
  ) async {
    final record = await userTransport.fetchRecoveryEscrow(client.workspaceId);
    if (record == null) {
      throw const RecoveryEscrowException(
        RecoveryEscrowFailure.noEscrowStored,
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
    return (record, root, secrets);
  }

  /// Steps 2 through 7 — everything after Root is in hand.
  Future<void> _registerThisDevice(
    RootAuthority root, {
    required Uint8List masterWrapKey,
    required bool encryptFromGenesis,
  }) async {
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
      // 6b. The key plane, once this device is a granted Member of the Workspace.
      //     Two mutually exclusive cases, decided by what the Workspace already is:
      //
      //     - it holds epoch keys already -> adopt them from the escrow wraps.
      //       This is the passphrase-alone path, and it needs no second device
      //       online and no round-trip with one.
      //     - it holds none, and this ceremony founded it, and the caller asked for
      //       encryption -> mint `K_{w,0}` and publish the set.
      //
      //     Adoption runs first and unconditionally, because "the Workspace is
      //     already encrypted" is a fact to discover rather than a state to assume:
      //     a device that skipped it and then keyed epoch 0 itself would be refused
      //     by the digest, and rightly.
      await _adoptOrMintEpochKeys(
        workspace,
        masterWrapKey: masterWrapKey,
        encryptFromGenesis: encryptFromGenesis,
      );
    }
    // 7. Root is dropped by the caller's `finally`, whatever happened here.
  }

  /// The key plane for one Workspace at the end of its enrolment.
  Future<void> _adoptOrMintEpochKeys(
    String workspaceId, {
    required Uint8List masterWrapKey,
    required bool encryptFromGenesis,
  }) async {
    final scoped = await _scoped(workspaceId);
    final ceremony = WorkspaceKeyCeremony(client: scoped, random: _random);
    if (await ceremony.adoptFromEscrow(masterWrapKey: masterWrapKey) > 0) {
      // The Workspace was already encrypted, so the history this device just pulled
      // is quarantined behind the keys it did not have while pulling. One re-pull
      // releases it: the ops are in the quarantine, and the release scan re-receives
      // every row whose epoch is now readable.
      await scoped.pull();
      return;
    }
    if (!encryptFromGenesis) return;
    if (await scoped.workspaceKeys.highestEpochHeld(workspaceId) != null) {
      // Adoption learning nothing does not mean the Workspace is unkeyed: a re-run
      // on a device that already holds every epoch's key learns zero too. Minting
      // is only for a Workspace with no keyed epoch at all — publishing a second
      // `K_{w,0}` over a keyed one would be refused by the stored digest anyway,
      // so this turns a guaranteed refusal into the idempotent re-run it is.
      return;
    }
    await ceremony.publish(await ceremony.prepare(
      epoch: 0,
      masterWrapKey: masterWrapKey,
    ));
  }

  /// The two Workspaces every enrolment covers, in the order it covers them.
  List<String> get _workspaces => derivableWorkspaceIds(client.userId);

  /// This device's client for one of its Workspaces.
  Future<SyncClient> _scoped(String workspaceId) async =>
      workspaceId == client.workspaceId ? client : await workspaceClientFactory(workspaceId);

  // --- Ceremony serialization --------------------------------------------------

  /// One lock per `EnrolmentService` instance, and this service is built once per
  /// User (its [_workspaces] are `derivableWorkspaceIds(client.userId)`), so the
  /// grain is **per-User**. A single ceremony already spans both Workspaces
  /// sequentially, so there is never a legitimate reason to run two ceremonies for
  /// one User at once — a per-Workspace lock would only force a ceremony to hold two
  /// of them across the whole run and reintroduce lock-ordering risk for no benefit.
  ///
  /// Built on the future-chain idiom [PendingRotationStore] uses, but with two
  /// acquisition modes rather than one: [_runCeremonyExclusive] waits (FIFO), and
  /// [_tryRunCeremonyExclusive] skips when busy. There is no `Mutex`/`synchronized`
  /// package in this codebase to lean on.

  /// The tail of the ceremony chain: completes when the last enqueued ceremony (a
  /// waiting rotation, or a try-acquired resume that actually ran) releases. A
  /// waiting ceremony chains onto it; a try-acquiring resume runs only when nothing
  /// is in flight.
  Future<void> _ceremonyTail = Future<void>.value();

  /// How many ceremonies are **enqueued or running**. Incremented at *enqueue*
  /// (before the body starts), decremented when the body settles.
  ///
  /// A counter, not a bare "running" flag, and incremented at enqueue rather than at
  /// body-start, so a try-acquiring resume checking `> 0` cannot slip into the window
  /// between a ceremony being enqueued and its body actually starting — the secondary
  /// hazard #624 calls out.
  int _ceremoniesInFlight = 0;

  /// Run [body] under the ceremony lock, **waiting** (FIFO) for any in-flight
  /// ceremony to finish first. What a full rotation does — it must never race another.
  Future<T> _runCeremonyExclusive<T>(Future<T> Function() body) {
    _ceremoniesInFlight++;
    final previous = _ceremonyTail;
    final next = previous.then((_) => body());
    // The tail swallows the body's error (so a failed ceremony does not poison the
    // next one's chain) and drops the in-flight count exactly once, when this body
    // settles — success or throw.
    _ceremonyTail = next.then<void>(
      (_) => _ceremoniesInFlight--,
      onError: (Object _) => _ceremoniesInFlight--,
    );
    return next;
  }

  /// Run [body] under the ceremony lock only if **nothing is in flight**; otherwise
  /// skip it and return at once. What the resume triggers do — they never block.
  ///
  /// A successful acquire delegates to [_runCeremonyExclusive], so a resume that does
  /// run is registered in-flight and chained onto the tail for its whole duration —
  /// a `rotateWorkspaceKeys` starting mid-resume then waits for it rather than racing
  /// its operations. The try-body is never run off-chain.
  Future<void> _tryRunCeremonyExclusive(Future<void> Function() body) {
    if (_ceremoniesInFlight > 0) return Future<void>.value();
    return _runCeremonyExclusive(body);
  }

  // --- Key rotation ------------------------------------------------------------

  /// Turn encryption **on** for every Workspace of this User.
  ///
  /// Turn-on *is* a rotation, and that is the point rather than a shortcut: the owner
  /// mints `K_{w,N+1}`, authors `rotate(N -> N+1)`, publishes the wrap set, and
  /// authors content under the new key from then on. There is no separate switch and
  /// no second machine to get wrong — and because the new epoch is `N+1`, every
  /// content op already in the log stays at an *unkeyed* epoch and stays readable
  /// for ever. Minting `K_{w,N}` instead would have keyed the past retroactively and
  /// turned the whole existing history into a refusal on every device.
  ///
  /// Idempotent in the only sense that matters: running it on an already-encrypted
  /// Workspace rotates it, which is a legal thing to do at any time.
  ///
  /// Serializes with every other ceremony for this User through [rotateWorkspaceKeys]
  /// — it takes no lock of its own, so a ceremony acquires exactly once (#624).
  Future<Map<String, int>> turnOnEncryption({required String passphrase}) =>
      rotateWorkspaceKeys(passphrase: passphrase);

  /// Revoke a Device and rotate every Workspace's key in one ceremony.
  ///
  /// **The two halves are inseparable**, which is why there is no `revokeDevice`
  /// beside this. A revocation alone stops the Device *authoring*; it does nothing
  /// about the key already on it, so a revoked Device that kept receiving would keep
  /// reading. The rotation is what makes the revocation mean something, and the
  /// wrap set for the new epoch simply has no entry for the revoked Member.
  ///
  /// **Nothing is authored until every survivor's wrap exists** (review F14a). The
  /// wrap set is built first, and a survivor that cannot be wrapped to raises
  /// [SyncRejectionReason.unwrappableGrant] with the log untouched — no revoke, no
  /// rotate, no PUT. A half-run ceremony here would either leave a Device revoked
  /// with the key still valid, or publish a signed digest that locks an honest
  /// Member out permanently.
  ///
  /// Takes the passphrase because only Root may revoke an owner Grant (ADR-0031) and
  /// every Device holds one — the deliberate corollary of "Devices are owners".
  ///
  /// Serializes with every other ceremony for this User through [rotateWorkspaceKeys]
  /// — it takes no lock of its own, so a ceremony acquires exactly once (#624).
  Future<Map<String, int>> revokeAndRotate({
    required String passphrase,
    required String memberId,
  }) {
    if (memberId == client.identity.memberId) {
      // A device revoking itself would author the revoke, rotate away from its own
      // key, and then be unable to read the Workspace it is still holding open. The
      // ceremony for retiring *this* device is running this one from another device.
      throw ArgumentError('a Device cannot revoke and rotate against itself');
    }
    return rotateWorkspaceKeys(passphrase: passphrase, revokeMemberId: memberId);
  }

  /// Rotate every Workspace of this User to its next epoch, optionally cutting one
  /// Member off on the way.
  ///
  /// Returns the epoch each Workspace now stands at. Both Workspaces, because a
  /// revoked Device must lose the preferences log as well as the GTD one, and
  /// because a User's preferences are exactly as private as their tasks.
  Future<Map<String, int>> rotateWorkspaceKeys({
    required String passphrase,
    String? revokeMemberId,
  }) =>
      // A full ceremony waits (FIFO) for any in-flight ceremony to finish first, so
      // two overlapping ceremonies for this User run one-after-the-other rather than
      // both reading the same `epochFloor`, preparing distinct sets for one `toEpoch`
      // and racing the `put` — #624. `turnOnEncryption` and `revokeAndRotate` reach
      // here and take no lock of their own, so a ceremony acquires exactly once.
      _runCeremonyExclusive(() => _rotateWorkspaceKeysCore(
            passphrase: passphrase,
            revokeMemberId: revokeMemberId,
          ));

  /// The rotation ceremony proper, run under the ceremony lock its wrapper holds.
  Future<Map<String, int>> _rotateWorkspaceKeysCore({
    required String passphrase,
    String? revokeMemberId,
  }) async {
    // Finish any rotation this User left stranded before starting a new one. This
    // also delivers AC-5: `_rotateOne` writes its own record before its own flush,
    // so a throw on the second Workspace leaves the first with no record (deleted on
    // its success) and the second with a live one — the next ceremony resumes only
    // the second and does not re-rotate the first.
    //
    // The *unlocked* core, never the public `resumePendingRotations` wrapper: this
    // ceremony already holds the lock, and re-entering it would deadlock a wait-mutex
    // or (with this try-skip resume) silently skip the drain the ceremony depends on.
    await _resumePendingRotationsCore();
    final (_, root, secrets) = await _recoverRoot(passphrase);
    try {
      final epochs = <String, int>{};
      for (final workspace in _workspaces) {
        epochs[workspace] = await _rotateOne(
          workspace,
          root: root,
          masterWrapKey: secrets.masterWrapKey,
          revokeMemberId: revokeMemberId,
        );
      }
      return epochs;
    } finally {
      root.drop();
    }
  }

  /// One Workspace's rotation, in the one order that is safe.
  ///
  /// ```
  /// 1. build the wrap set for N+1 over the survivors   (refuses here, or never)
  /// 2. author revoke(s), then rotate committing to the digest
  /// 3. flush — the rotate must be materialised before the wraps are accepted
  /// 4. PUT the wraps, and only then remember the key locally
  /// 5. pull, which applies the rotate and raises this device's epoch floor
  /// ```
  ///
  /// Step 3 before step 4 is the server's rule, not a preference: a wraps upload
  /// arriving before its `rotate` is refused as `rotate_not_materialised`, because a
  /// digest the log has not committed to is just a number the uploader chose.
  ///
  /// Step 5 is what turns the key into an authoring key. `capture` authors at the
  /// floor, and the floor rises only when the verified rotate applies — so between
  /// step 4 and step 5 this device holds `K_{w,N+1}` and still authors at `N`, which
  /// is a legal state rather than a window to close.
  Future<int> _rotateOne(
    String workspaceId, {
    required RootAuthority root,
    required Uint8List masterWrapKey,
    String? revokeMemberId,
  }) async {
    final scoped = await _scoped(workspaceId);
    // Pull first: the survivor set and the chain link both come from the applied
    // control log, and rotating against a stale view of who holds a Grant is how a
    // Member added a moment ago gets locked out.
    await scoped.pull();

    final fromEpoch = await scoped.epochFloor();
    final toEpoch = fromEpoch + 1;
    final ceremony = WorkspaceKeyCeremony(client: scoped, random: _random);
    final keySet = await ceremony.prepare(
      epoch: toEpoch,
      masterWrapKey: masterWrapKey,
      excludeMemberId: revokeMemberId,
    );

    // Persist the prepared set *before authoring anything*, not merely before the
    // flush. `prepare` has already fixed `keySet.digest`, so this commits nothing
    // prematurely — but on a single-isolate event loop any `await` between authoring
    // the rotate and writing the record could yield to a background lifecycle flush
    // that materialises the just-authored rotate before the record exists, which is
    // the exact stranded state this store exists to prevent. The only state this
    // ordering introduces is record-exists-but-rotate-never-authored (a crash before
    // the `captureControl` below), which is safe: nothing materialised, no floor
    // moved, and `resumePendingRotations` discards it on `rotate_not_materialised`.
    await pendingRotations.put(workspaceId, keySet);

    var head = await scoped.appliedControlHead();
    if (revokeMemberId != null) {
      final view = await scoped.grantsView();
      final doomed = view.grants.values
          .where((grant) => grant.memberId == revokeMemberId && grant.isLive)
          .toList()
        ..sort((a, b) => a.grantedSeq.compareTo(b.grantedSeq));
      if (doomed.isEmpty) {
        throw SyncRejection(
          SyncRejectionReason.unknownGrant,
          'no live Grant for $revokeMemberId in $workspaceId to revoke',
        );
      }
      for (final grant in doomed) {
        // Grant-granular, so a Member holding several loses each one explicitly
        // (review F19). Root signs every one of them: a Device's Grant is an owner
        // Grant, and only Root may unmake one.
        final certificate = RevokeCertificate(
          workspaceId: workspaceId,
          revokeId: const Uuid().v4(),
          grantId: grant.grantId,
          revoker: granterRoot,
          revokedAtHlc: Hlc.forMember(scoped.identity.memberId, _nowMs()),
        );
        final certBytes = certificate.encode();
        final payload = ControlPayload(
          controlType: controlTypeRevoke,
          prevControlHash: head,
          certBytes: certBytes,
          signature: await root.signRevokeCertificateBytes(certBytes),
          authority: granterRoot,
        ).encode();
        await scoped.captureControl(payload);
        head = controlPayloadHash(payload);
      }
    }

    final rotatePayload = ControlPayload(
      controlType: controlTypeRotate,
      prevControlHash: head,
      rotate: RotateStatement(
        workspaceId: workspaceId,
        fromEpoch: fromEpoch,
        toEpoch: toEpoch,
        keyWrapDigest: keySet.digest,
        rotatedAtHlc: Hlc.forMember(scoped.identity.memberId, _nowMs()),
      ),
    ).encode();
    await scoped.captureControl(rotatePayload);
    await scoped.flushOutbox();
    await ceremony.publish(keySet);
    // `publish` remembered the key, so the record has done its job. Removing it here
    // keeps the steady state empty; a crash between `publish` and this line leaves a
    // stale record whose epoch the device already holds a key for, which
    // `resumePendingRotations` discards rather than re-publishing (AC-7).
    await pendingRotations.remove(workspaceId, keySet.epoch);
    await scoped.pull();
    return scoped.epochFloor();
  }

  /// Re-publish any prepared wrap set whose rotate materialised but whose key was
  /// never remembered — the passphrase-free resume of a crashed [_rotateOne].
  ///
  /// Because the persisted record already carries `workspaceKey`, the member wraps,
  /// the escrow wrap and the digest, this needs **no passphrase and no
  /// `master_wrap_key`**: `publish` is member-scoped, and that is exactly what lets
  /// this run from the pull tail and from launch, not only from the next
  /// passphrase-gated ceremony. Scoped to [workspaceId] when given (one per pull
  /// listener), otherwise every derivable Workspace.
  ///
  /// Best-effort by contract: a transient/offline failure leaves the record for the
  /// next trigger, and the only records it *deletes* are the ones it has provably
  /// finished (key now held) or that never materialised a rotate to finish. A
  /// refusal no retry can change is neither deleted nor retried — it is marked
  /// terminal and alarmed (#627, [_resumePendingRotationsCore]).
  Future<void> resumePendingRotations({String? workspaceId}) =>
      // Try-acquire, and skip if any ceremony is in flight — the resume triggers
      // never block (AC-5): the launch resume is awaited inside activation and the
      // pull-tail resume gates the next pull, so queuing behind a long ceremony would
      // stall both. Skipping loses no work: the lock-holder drains every stranded
      // record first (`_rotateWorkspaceKeysCore` calls `_resumePendingRotationsCore`
      // at the top), and any record it authors it survives a crash for the next
      // trigger. A *successful* try-acquire still registers in-flight and chains onto
      // the tail, so a `rotateWorkspaceKeys` starting mid-resume waits for it (#624).
      _tryRunCeremonyExclusive(
          () => _resumePendingRotationsCore(workspaceId: workspaceId));

  /// Attempts an unclassified refusal has already spent, per `(workspace, epoch)`
  /// for the publish surface and per `(workspace)` for the flush surface.
  ///
  /// **In memory, so per process.** That is the point: a code this build cannot name
  /// must never produce a durable terminal record, so a relaunch re-attempts under a
  /// fresh budget and a transient-but-unclassified code self-heals. The cost is that
  /// a frequently-killed app may never exhaust a budget — stated in
  /// [maxUnclassifiedResumeRefusalAttempts], and the fail-safe direction.
  final Map<String, int> _unclassifiedRefusalAttempts = {};

  /// Budgets already spent, so a spent one is not re-alarmed on every later pass.
  /// A publish key here also stops the PUT being re-issued for the rest of the
  /// process; a flush key only stops the re-alarm, because the outbox drain is
  /// ordinary sync work and not this resume's to abandon.
  final Set<String> _exhaustedRefusalBudgets = {};

  /// The resume proper, run under the ceremony lock — either its own try-acquire, or
  /// directly by a ceremony that already holds the lock (the internal drain). Never
  /// takes the lock itself, so the ceremony's internal call cannot re-enter it.
  ///
  /// Per Workspace, in this order, and the order is load-bearing:
  ///
  /// 1. read the **resumable** records — a terminal one is retained but not re-PUT;
  /// 2. discard the records whose epoch this device already holds a key for,
  ///    *before* any flush, so a pass whose every record is stale still performs no
  ///    flush;
  /// 3. **one flush for the whole Workspace**, hoisted out of the per-epoch loop.
  ///    `flushOutbox` is one call per Workspace, so a refusal is not attributable to
  ///    whichever epoch a loop happened to be on — and attributing it would let a
  ///    stale rotate for `N+2` terminalise the sound record for `N+1`. It raises
  ///    `own_write_refused_permanently` and never terminalises anything;
  /// 4. per epoch, publish, and dispatch any refusal through
  ///    [dispositionForResumeRefusal].
  ///
  /// A failed flush does **not** skip the publishes: per-epoch independence is the
  /// behaviour that was there before the hoist. One guard is required, and it is a
  /// real trap — with the flush unsuccessful, `rotate_not_materialised` is downgraded
  /// from `discard` to `retry`. Discarding is only safe once a flush has drained
  /// whatever this device authored; doing it after a failed flush would delete the
  /// wrap set for an epoch whose rotate is still sitting in the outbox, which is the
  /// exact orphaning `PendingRotationStore` exists to prevent. Every other verdict is
  /// unaffected: an unflushed rotate of ours cannot materialise an epoch the server
  /// already holds a different digest for.
  Future<void> _resumePendingRotationsCore({String? workspaceId}) async {
    final targets = workspaceId == null ? _workspaces : [workspaceId];
    // Per-record best-effort: a transient failure on one record must not abandon
    // the epochs behind it or the other Workspaces — they are independent. Hold the
    // first such failure and rethrow it once the whole pass has run, so the caller
    // still learns the pass did less than complete (the pull tail and launch swallow
    // it; a fresh ceremony propagates it).
    Object? firstFailure;
    StackTrace? firstStackTrace;
    // Carry the *caught* stack trace — where `flushOutbox`/`publish` actually
    // failed — not the rethrow site below, so the rethrow points at the cause.
    void hold(Object error, StackTrace stackTrace) {
      firstFailure ??= error;
      firstStackTrace ??= stackTrace;
    }

    for (final workspace in targets) {
      final Map<int, EpochKeySet> resumable;
      try {
        resumable = await pendingRotations.readResumable(workspace);
      } on Object catch (error, stackTrace) {
        // A keychain read that throws must not abandon the other Workspace.
        hold(error, stackTrace);
        continue;
      }
      if (resumable.isEmpty) continue;
      final scoped = await _scoped(workspace);
      // No member credential (a pre-enrolment or mid-attach caller): leave every
      // record and let a trigger that holds one finish it.
      if (!scoped.isEnrolled) continue;

      // Step 2 — lowest epoch first. Independent of each other, but deterministic
      // order keeps a failure reproducible.
      final publishable = <int, EpochKeySet>{};
      for (final epoch in resumable.keys.toList()..sort()) {
        try {
          // Already complete: the original ceremony's `publish` remembered the key
          // before it could delete the record (a crash in that one-line gap). Stale,
          // not a retry — discard it (AC-7).
          if (await scoped.workspaceKeys.keyFor(workspace, epoch) != null) {
            await pendingRotations.remove(workspace, epoch);
            continue;
          }
        } on Object catch (error, stackTrace) {
          hold(error, stackTrace);
          continue;
        }
        publishable[epoch] = resumable[epoch]!;
      }
      // Step 3 — nothing left to publish, so nothing to flush for either.
      if (publishable.isEmpty) continue;

      final flushSucceeded = await _flushBeforeResume(scoped, workspace, hold);

      // Step 4 — `publishable` preserves the sorted insertion order.
      for (final epoch in publishable.keys) {
        if (_exhaustedRefusalBudgets.contains(_refusalBudgetKey(workspace, epoch))) {
          continue;
        }
        try {
          // Byte-identical re-PUT returns 200 (server-side idempotency, #590), then
          // `publish` remembers the key and this device finally holds K_{w,epoch}.
          await WorkspaceKeyCeremony(client: scoped).publish(publishable[epoch]!);
          await pendingRotations.remove(workspace, epoch);
        } on SyncTransportException catch (error, stackTrace) {
          try {
            final held = await _disposePublishRefusal(
              scoped,
              workspace: workspace,
              epoch: epoch,
              refusal: error,
              flushSucceeded: flushSucceeded,
            );
            if (held) hold(error, stackTrace);
          } on Object catch (localError, localStackTrace) {
            // A keychain write, a `remove`, or an **alarm write** that threw. Hold
            // and continue: the record stays where it is, and the next pass retries
            // both the mark and the alarm. Before the hoist a throw here abandoned
            // every remaining epoch and the other Workspace (AC-5).
            hold(localError, localStackTrace);
          }
        } on Object catch (error, stackTrace) {
          hold(error, stackTrace);
        }
      }
    }
    // Read into a local: `firstFailure` is written through the [hold] closure, so
    // the analyzer cannot promote the field itself to non-null.
    final failure = firstFailure;
    if (failure != null) {
      Error.throwWithStackTrace(failure, firstStackTrace ?? StackTrace.current);
    }
  }

  /// Drain a rotate that was authored but never flushed (a crash between the
  /// `captureControl` and the flush), once for the whole Workspace.
  ///
  /// Op-id-namespaced, so a no-op when the outbox is empty. Returns whether the
  /// flush got through, which the `discard` downgrade in
  /// [_resumePendingRotationsCore] turns on.
  ///
  /// A permanent refusal here raises `own_write_refused_permanently` and stops
  /// there: the queue behind an unpostable op is #647's to drain, and this pass has
  /// no record it may honestly blame.
  Future<bool> _flushBeforeResume(
    SyncClient scoped,
    String workspace,
    void Function(Object, StackTrace) hold,
  ) async {
    try {
      await scoped.flushOutbox();
      return true;
    } on SyncTransportException catch (error, stackTrace) {
      try {
        final disposition = dispositionForResumeRefusal(
          error,
          surface: RotationResumeSurface.flush,
        );
        switch (disposition) {
          case RotationResumeDisposition.permanent:
            await scoped.raiseOwnWriteRefusedPermanentlyAlarm(
              detail: _ownWriteRefusedDetail(workspace, error, budgetExhausted: false),
            );
          case RotationResumeDisposition.retryBounded:
            final key = _refusalBudgetKey(workspace, null);
            if (_spendRefusalBudget(key)) {
              await scoped.raiseOwnWriteRefusedPermanentlyAlarm(
                detail:
                    _ownWriteRefusedDetail(workspace, error, budgetExhausted: true),
              );
            }
          // A flush is ordinary sync work: `discard` has no meaning on this surface
          // (the classifier never returns it here) and a transient refusal is simply
          // the next pull's business.
          case RotationResumeDisposition.discard:
          case RotationResumeDisposition.retry:
            break;
        }
      } on Object catch (alarmError, alarmStackTrace) {
        hold(alarmError, alarmStackTrace);
      }
      hold(error, stackTrace);
      return false;
    } on Object catch (error, stackTrace) {
      hold(error, stackTrace);
      return false;
    }
  }

  /// Act on one refused resume PUT. Returns whether the refusal should still be
  /// held for the post-pass rethrow (a `discard` should not — it is a success).
  ///
  /// **Alarm first, mark second.** If `markTerminal` then fails the alarm still
  /// stands and the next pass retries the mark, whereas marking first and failing
  /// the alarm write would leave a *silent* terminal record. The two writes are in
  /// independent stores (drift `integrity_alarms` and the keychain) so there is no
  /// transaction to share, and the reverse failure is benign because the alarm
  /// upserts. Accepted degradation: a persistently-failing mark re-raises on every
  /// pull, which un-resolves an alarm a user had dismissed (#575). That is the
  /// correct precedence — a record still churning is a condition that still stands —
  /// but it is a real cost, not a rounding error.
  Future<bool> _disposePublishRefusal(
    SyncClient scoped, {
    required String workspace,
    required int epoch,
    required SyncTransportException refusal,
    required bool flushSucceeded,
  }) async {
    final disposition = dispositionForResumeRefusal(
      refusal,
      surface: RotationResumeSurface.publish,
    );
    switch (disposition) {
      case RotationResumeDisposition.discard:
        if (!flushSucceeded) {
          // Downgraded to `retry`: see [_resumePendingRotationsCore]. Deleting now
          // would destroy a wrap set whose rotate is still in the outbox.
          return true;
        }
        // The rotate was never authored (a premature record per `_rotateOne`'s
        // persist-before-author ordering — safe because the `WorkspaceEpoch` row is
        // created atomically with the rotate). Discard it: the owner can re-run the
        // whole ceremony fresh with new entropy, nothing stranded.
        await pendingRotations.remove(workspace, epoch);
        return false;
      case RotationResumeDisposition.retry:
        // Offline, or a server that never got as far as judging the set. Leave the
        // record for the next trigger, spend no budget.
        return true;
      case RotationResumeDisposition.retryBounded:
        if (_spendRefusalBudget(_refusalBudgetKey(workspace, epoch))) {
          // Alarm and stop re-attempting for this process. Nothing is persisted, so
          // a relaunch re-attempts under a fresh budget.
          await scoped.raiseEpochKeySetUnpublishableAlarm(
            detail: _unpublishableDetail(
              workspace: workspace,
              epoch: epoch,
              refusal: refusal,
              budgetExhausted: true,
            ),
          );
        }
        return true;
      case RotationResumeDisposition.permanent:
        await scoped.raiseEpochKeySetUnpublishableAlarm(
          detail: _unpublishableDetail(
            workspace: workspace,
            epoch: epoch,
            refusal: refusal,
            budgetExhausted: false,
          ),
        );
        await pendingRotations.markTerminal(
          workspace,
          epoch,
          refusalCode: refusal.code!,
          markedAtUtc:
              DateTime.fromMillisecondsSinceEpoch(_nowMs(), isUtc: true),
        );
        return true;
    }
  }

  /// `(workspace, epoch)` for the publish surface, `(workspace)` for the flush one.
  String _refusalBudgetKey(String workspace, int? epoch) =>
      epoch == null ? 'flush/$workspace' : 'publish/$workspace/$epoch';

  /// Spend one attempt. True exactly once — on the attempt that exhausts the
  /// budget — so the alarm is raised at exhaustion and not re-raised for ever after
  /// it for a code that was never classified in the first place.
  bool _spendRefusalBudget(String key) {
    if (_exhaustedRefusalBudgets.contains(key)) return false;
    final spent = (_unclassifiedRefusalAttempts[key] ?? 0) + 1;
    _unclassifiedRefusalAttempts[key] = spent;
    if (spent < maxUnclassifiedResumeRefusalAttempts) return false;
    _exhaustedRefusalBudgets.add(key);
    return true;
  }

  /// Displayable on its own, for #584: nothing here needs this call site to read.
  String _unpublishableDetail({
    required String workspace,
    required int epoch,
    required SyncTransportException refusal,
    required bool budgetExhausted,
  }) =>
      'Workspace $workspace epoch $epoch: the prepared KeyWrap set cannot be '
      'published. The server refused the upload with '
      '${refusal.code ?? '(no structured code)'} '
      '(HTTP ${refusal.statusCode ?? 'unreachable'})'
      '${budgetExhausted ? ', repeatedly and under a code this build does not '
          'classify, so re-attempts have stopped for this run of the app' : ', '
          'under a code no retry can change'}. The prepared bytes are retained on '
      'this device and nothing was deleted.';

  /// Same contract as [_unpublishableDetail]: epoch-agnostic, because a flush is one
  /// call per Workspace and blames no single record.
  String _ownWriteRefusedDetail(
    String workspace,
    SyncTransportException refusal, {
    required bool budgetExhausted,
  }) =>
      'Workspace $workspace: an op this device authored was refused with '
      '${refusal.code ?? '(no structured code)'} '
      '(HTTP ${refusal.statusCode ?? 'unreachable'})'
      '${budgetExhausted ? ', repeatedly and under a code this build does not '
          'classify' : ' and no retry can change that answer'}, so everything '
      'queued behind it cannot leave this device.';

  /// Whether any of this User's Workspaces has stood at its epoch too long.
  ///
  /// The scheduled-rotation trigger. It reports and does not act: minting an epoch
  /// writes an escrow wrap under `master_wrap_key`, which lives behind the
  /// passphrase, so a quarterly rotation is a prompt the surface raises rather than
  /// a background job — and caching the master wrap key on the device to make it
  /// unattended would move escrow material out from behind the passphrase for a
  /// convenience.
  ///
  /// Unencrypted Workspaces are never "due": turning encryption on is an owner's
  /// decision, not a timer's.
  Future<List<String>> workspacesDueForRotation({
    Duration maxEpochAge = quarterlyRotationInterval,
  }) async {
    final due = <String>[];
    final now = DateTime.fromMillisecondsSinceEpoch(_nowMs(), isUtc: true);
    for (final workspace in _workspaces) {
      final scoped = await _scoped(workspace);
      final isDue = await WorkspaceKeyCeremony(client: scoped, random: _random)
          .isRotationDue(now: now, maxEpochAge: maxEpochAge);
      if (isDue) due.add(workspace);
    }
    return due;
  }

  /// Write the slot if it is empty, and **pin Root for it either way**.
  ///
  /// The pin is per `(workspace, user)` because the escrow slot is: each Workspace
  /// resolves its own `root_pk`, so a device that pinned only one of them could
  /// not verify a control op in the other. Skipping the pin is what leaves the
  /// second Workspace's log unverifiable and its genesis re-authored for ever.
  Future<void> _writeEscrowSlot(RootAuthority root, String workspaceId) async {
    final scoped = await _scoped(workspaceId);
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
    final scoped = await _scoped(workspaceId);

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
