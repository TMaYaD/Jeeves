/// Capture, push, pull, verify, reduce — the client half of the sync spine.
///
/// `sync()` is explicit and this class stays a verb-set: staying subscribed to
/// the payload-free "there's news" signal is a policy, and it lives in
/// `signal_listener.dart`. Everything else is here — the offline queue is
/// simply the outbox surviving a failed POST, and the pull loop runs the
/// fail-closed receive pipeline before anything reaches the reducer.
///
/// **The receive order is normative:**
///
/// ```
/// verifyEnvelope -> parseBody -> op_class routing -> per-author chain verdict
///                -> reducer guards -> apply -> clock.receive
/// ```
///
/// with one named carve-out: for `op_class = 2` the envelope-signature check
/// **defers** out of the first stage and into step 4 of the control
/// verification below. A MemberRegister's author key is unknowable before its
/// certificate parses — the directory by definition has no entry for an author
/// that is registering itself. The deviation is confined to control ops and
/// ends at that step; nothing else skips or reorders `verifyEnvelope`.
///
/// Three of those positions are load-bearing rather than incidental:
///
/// * The **chain verdict sits after decode**, because only an authentically
///   signed *and* codec-valid envelope may advance or accuse an author's chain.
///   Placed earlier, a server could poison an author's chain state with forged
///   garbage under their id, and a run of undecodable ops under one author would
///   log the first and then misclassify the rest as chain rewrites.
/// * **`_clock.receive` fires only on a successful apply.** A refused
///   `hlc_in_the_future` op must not be able to drag the local clock to the very
///   timestamp the guard just refused.
/// * A **reducer-guard refusal is still logged**, marked with its
///   `refused_reason`. Withholding it would make the author's honest next op
///   read as a chain gap. The codec-level invariant is untouched: an envelope
///   refused before the chain verdict never reaches `op_log` at all.
///
/// Control ops carry `author_seq` and `prev_author_hash` like any other, and
/// their logged envelopes are what later content ops chain to — but their own
/// position is checked by the control verification's own rules (a register is its
/// author's op 1, chained across authors by payload hash), not by the per-author
/// verdict. Control-op chain verification and `epoch_floor` are #549's.
///
/// There is no `refreshMemberDirectory`. A MemberRegister is its author's op 1
/// and seq ordering guarantees it is pulled before any of that author's content
/// ops, so the pull itself hydrates the directory in order. A directory refresh
/// racing a pull is not a hazard this client manages; it is a hazard this
/// client cannot have. After a relaunch the directory is restored from the
/// applied control log at assembly, because the pull cursor outlives the
/// process and the registrations would never be served again.
library;

import 'dart:async' show Completer, unawaited;
import 'dart:math' show Random, max, min;

import 'package:drift/drift.dart';
// The append to `op_log` is a plain insert whose uniqueness constraints are the
// authority on a taken slot (see [SyncClient._logReceived]), so this file has to
// be able to tell that one failure apart from every other database failure.
// `common.dart` is the platform-neutral half of the package: the exception type
// and the result codes, no FFI.
import 'package:sqlite3/common.dart' show SqlExtendedError, SqliteException;
import 'package:uuid/uuid.dart';

import 'alarm_resolution.dart';
import 'chain_verifier.dart';
import 'collection_codecs.dart' show userPreferencesCollection;
import 'control_payload.dart';
import 'domain_projector.dart';
import 'host/change.dart';
import 'host/sync_host_service.dart';
import 'domain_reconciler.dart';
import 'envelope.dart';
import 'grants_view.dart';
import 'hlc.dart';
import 'key_wraps.dart';
import 'member_identity.dart';
import 'op_payload.dart';
import 'prune_payload.dart';
import 'reducer.dart';
import 'recovery_escrow.dart';
import 'sync_condition_class.dart';
import 'sync_database.dart';
import 'sync_health.dart';
import 'sync_transport.dart';
import 'workspace_key_store.dart';

/// not tunable per call: one page is a batch of ops, sized to keep a bootstrap
/// pull to a handful of round-trips without an unbounded response body.
const int defaultPullPageLimit = 500;

/// The extended result codes that mean *the slot this row claims is taken*.
///
/// The only append failure the receive pipeline is allowed to swallow. Every
/// other SQLite failure is a database problem rather than an accusation, and
/// filing one as a slot collision would both mislabel it and permanently skip an
/// op the next sync could have retried.
const Set<int> _slotTakenResultCodes = {
  SqlExtendedError.SQLITE_CONSTRAINT_PRIMARYKEY,
  SqlExtendedError.SQLITE_CONSTRAINT_UNIQUE,
};

/// Whether an arriving control op takes its position, or loses a fork.
enum _ControlPosition { accept, quarantineThis }

/// One logged op that writes to a particular entity — what a compaction pass needs
/// to know about a candidate target without re-decoding it.
///
/// The envelope travels because the prune's attestation is a hash of it, and the
/// three header fields because the attestation names them.
typedef LoggedEntityOp = ({
  int seq,
  String authorMemberId,
  int authorSeq,
  int opClass,
  Uint8List envelope,
});

/// A control op whose bytes have verified, and nothing more.
///
/// The seam that lets the receive path log the envelope between verification and
/// application: [learned] is the registration the op *would* teach this device,
/// carried rather than remembered so a refusal leaves no key behind it.
class _VerifiedControlOp {
  _VerifiedControlOp({
    required this.payload,
    required this.payloadBytes,
    required this.learned,
  });

  final ControlPayload payload;
  final Uint8List payloadBytes;
  final RegistrationCertificate? learned;
}

/// The head of this Workspace's applied control log: the op every control op
/// chains on, and the transport `seq` it was logged at.
///
/// Both halves, because the two answer different questions. The hash is what an
/// arriving op names, and the `seq` is the boundary an arriving op has to sit
/// above: the log is ordered by transport `seq`, so its last row is the chain
/// head, and an op slotted under it would leave `applied.last` no longer the
/// head.
class _AppliedControlHead {
  const _AppliedControlHead({required this.seq, required this.payloadHash});

  final int seq;
  final Uint8List payloadHash;
}

/// The head of a Workspace that has applied no control op yet.
///
/// A value rather than null, so "this Workspace has no head" is a state the
/// scan compares against like any other — and not the same as "the scan has
/// not run yet", which is a different thing entirely: the first pull after a
/// launch runs the scan, and every pull after that must not. The `seq` sits
/// below every op's, so the empty head is never equal to a real one.
final _AppliedControlHead _noAppliedControlHead =
    _AppliedControlHead(seq: -1, payloadHash: zeroPrevControlHash);

/// What one [SyncClient.flushOutbox] concluded.
///
/// A return value rather than an exception because none of the three is an
/// error the caller should be forced to catch: only the enrolment ceremony acts
/// on the distinction, and [SyncClient.sync] is right to ignore it.
enum FlushOutcome {
  /// The queue was empty, or the server now holds everything that was in it.
  flushed,

  /// Nothing moved and the queue is retained: a 409 on our own chain, which
  /// re-numbers nothing and is recorded as a verdict instead (see
  /// [SyncClient.flushOutbox]). An unreachable server is not this — it throws,
  /// because "offline" is the caller's to see.
  retained,

  /// A queued `workspace_genesis` lost the founding race: another Root-holder
  /// founded this Workspace first. The staged ops are dropped and the author
  /// chain is rewound, so the queue is *not* wedged — the ceremony has to pull
  /// and claim its place on the register path instead.
  genesisSuperseded,
}

class SyncClient {
  SyncClient({
    required this.workspaceId,
    required this.userId,
    required this.identity,
    required SyncDatabase database,
    required HlcClock clock,
    required Reducer reducer,
    SyncTransport? transport,
    MemberDirectory? directory,
    WorkspaceKeyStore? workspaceKeys,
    this.pullPageLimit = defaultPullPageLimit,
    DateTime Function()? now,
  })  : _db = database,
        _clock = clock,
        _reducer = _reducerFor(reducer, workspaceId),
        _transport = transport,
        directory = directory ?? MemberDirectory(),
        workspaceKeys = workspaceKeys ?? InMemoryWorkspaceKeyStore(),
        _now = now ?? DateTime.now {
    this.directory.rememberSelf(identity);
  }

  /// The reducer this client reduces through, checked against its Workspace.
  ///
  /// **The two cannot disagree.** The reducer holds the rule that refuses a
  /// change whose collection belongs to another Workspace, and it holds it
  /// against *its own* Workspace identity — so a client paired with another
  /// Workspace's reducer would refuse every honest change, and a client paired
  /// with a reducer that thinks it is the preferences Workspace would apply
  /// another Workspace's collections. Either is a wiring mistake, and a
  /// constructor that refuses it is cheaper than a device that quietly
  /// mis-reduces.
  static Reducer _reducerFor(Reducer reducer, String workspaceId) {
    if (reducer.workspaceId != workspaceId) {
      throw ArgumentError(
        'a SyncClient for workspace $workspaceId cannot reduce through a '
        'reducer built for workspace ${reducer.workspaceId}',
      );
    }
    return reducer;
  }

  final String workspaceId;

  /// The owning User. Half of the escrow slot key, and not otherwise trusted.
  final String userId;

  /// Whether this client speaks for the User-global preferences Workspace.
  ///
  /// The one place a Workspace's *identity* changes a rule: preferences grant
  /// every Device and no Service ever, and the boundary is structural rather than
  /// a policy the reducer could be talked out of.
  bool get isPreferencesWorkspace => _reducer.isPreferencesWorkspace;

  /// Whether [collection] belongs to this client's Workspace.
  ///
  /// Mirrors the author-side routing (`user_preferences` goes to the preferences
  /// Workspace, every other collection to the GTD one). Merge state has no
  /// Workspace column, so this is how a rebuild tells its own entities from the
  /// other Workspace's on the same Device.
  ///
  /// The rule itself lives on the reducer, which is what refuses a change that
  /// crosses the line; this is the same answer, read from the same place.
  bool ownsCollection(String collection) => _reducer.ownsCollection(collection);
  final MemberIdentity identity;
  final MemberDirectory directory;

  /// The `epoch -> K_{w,epoch}` map this device holds, per Workspace.
  ///
  /// Empty means `plaintext_v1`, which is what every pre-turn-on Workspace is:
  /// nothing in this class decides to encrypt, it encrypts iff a key exists for the
  /// epoch it is authoring at. Shared with the other Workspace's client on the same
  /// device the way [directory] is — the store is keyed by Workspace, so one store
  /// per device is one scope per Workspace.
  final WorkspaceKeyStore workspaceKeys;

  /// The nonce source, and deliberately not a seam.
  ///
  /// A 24-byte XChaCha20 nonce repeated under one key is a catastrophic failure of
  /// the stream cipher, so there is no injectable entropy here for a test to seed —
  /// the golden vectors pin nonces by calling `sealBody` with a header they built,
  /// which is the only way to get a chosen nonce into an envelope.
  final Random _nonceEntropy = Random.secure();

  final int pullPageLimit;

  final SyncDatabase _db;
  final HlcClock _clock;
  final Reducer _reducer;
  final DateTime Function() _now;

  /// Feeds reduced state into the domain read model. Assigned after
  /// construction because the projector needs a `GtdDatabase` whose capture
  /// seam needs this client — the cycle is broken here rather than by giving
  /// either store a reference to the other. Null leaves reduction headless,
  /// which is what the collection-generic reducer tests want.
  DomainProjector? projector;

  /// Takes the convergence decisions the projector must not — the Tag fold and
  /// the dangling-junction rehome (see [DomainReconciler]).
  ///
  /// Driven from the **pull tail only**, never from [capture] or
  /// [captureCompaction]: its passes author ops, which re-enter [capture] and
  /// therefore projection, so a reconcile on the author path recurses. Null for
  /// the same reason [projector] is — a headless reducer has no read model to
  /// reconcile.
  DomainReconciler? reconciler;

  /// The app-owned sync host, when one exists. The rebuild consults it to carry
  /// across merge state the log never held (writes made under the device node id).
  SyncHostService? host;

  SyncTransport? _transport;

  /// The authors whose quarantined successors a release scan is currently
  /// re-admitting.
  ///
  /// Re-entry suppression, and the reason the fixpoint is one flat loop: a
  /// released op goes back through [_receive], and if that call started a nested
  /// scan of its own then a hostile 500-op reorder would heal in 500 recursive
  /// frames instead of 500 iterations.
  ///
  /// A **set** rather than one author since #555: a prune raises several authors'
  /// chain floors in one apply, so a scan for one author has to be able to trigger
  /// a scan for another. Only the same author re-entering is suppressed, which is
  /// the case the flat loop already covers.
  final Set<String> _releasingChainOfAuthors = <String>{};

  /// Quarantine rows of control ops applied late by
  /// [_releaseOpsAwaitingControlPredecessor], stamped released only after the
  /// pull-tail [rebuildFromOpLog] has recomputed the grant verdicts they change
  /// and projection has succeeded.
  ///
  /// The unreleased row is the durable record that the rebuild is owed: a process
  /// exit before the stamp makes the next scan find the op already applied, raise
  /// the rebuild obligation again and retry.
  final Set<int> _releaseAfterRebuild = <int>{};

  /// The pull in flight, and whether another pull was asked for while it ran.
  ///
  /// **One pull at a time** (#989). A pull reads the cursor, fetches a page and
  /// moves the cursor; two pulls doing that at once read the same cursor and
  /// fetch the same ops — the signal listener's poke-driven pull overlapping a
  /// manual sync. The ops are then received twice, and a refused op is filed
  /// twice.
  ///
  /// A caller that arrives while a pull is running does not start a second one:
  /// it asks for one more pull after the current one and waits for that, so
  /// nothing that arrived meanwhile is left unsynced. Waiting for the *next*
  /// pull rather than the current one is what keeps a poke from being lost:
  /// the op the poke announced may have landed after the running pull fetched
  /// its page, and only a further pull would fetch it.
  Future<void>? _pullInFlight;
  bool _pullQueued = false;

  /// The tail of the quarantine chain: completes when the last queued
  /// quarantine has finished.
  Future<void> _quarantineTail = Future<void>.value();

  /// The member-scoped transport, or a refusal if enrolment has not finished.
  ///
  /// A client without one is not "offline": it has no credential that speaks
  /// for this Device, and posting under anything else is what F10 forbids.
  SyncTransport get transport =>
      _transport ??
      (throw StateError(
        'this device has no member credential yet — run the enrolment ceremony',
      ));

  bool get isEnrolled => _transport != null;

  /// This device's HLC clock.
  ///
  /// Exposed for exactly one caller — a compaction pass stamping a snapshot's
  /// op-level clock — so that clock is the same one every other op of this device
  /// is stamped with rather than a second source that could disagree with it.
  HlcClock get clock => _clock;

  /// Attach the transport the proof-of-possession exchange returned.
  void useMemberTransport(SyncTransport memberTransport) {
    _transport = memberTransport;
  }

  // --- Pinned Root ------------------------------------------------------------

  /// The Root this device pinned for its escrow slot, or null before enrolment.
  Future<Uint8List?> pinnedRootPk() async => (await _rootPin())?.rootPk;

  /// The highest escrow version this device has accepted for its slot.
  Future<int> highestEscrowVersionSeen() async =>
      (await _rootPin())?.highestEscrowVersionSeen ?? 0;

  Future<RootPinRow?> _rootPin() => (_db.select(_db.rootPins)
        ..where((row) => row.workspaceId.equals(workspaceId) & row.userId.equals(userId)))
      .getSingleOrNull();

  /// Trust on first use, against the passphrase: record the Root that a
  /// successful unwrap produced, and the version it came at.
  Future<void> pinRoot(Uint8List rootPk, int escrowVersion) async {
    final existing = await _rootPin();
    if (existing != null && !sameBytes(existing.rootPk, rootPk)) {
      // Reaching here means an unwrap succeeded under a *different* Root than
      // the one already pinned, which no honest server can produce.
      throw const RecoveryEscrowException(
        RecoveryEscrowFailure.rootMismatch,
        'a different Root was recovered for a slot that is already pinned',
      );
    }
    final seen = existing?.highestEscrowVersionSeen ?? 0;
    await _db.into(_db.rootPins).insertOnConflictUpdate(
          RootPinsCompanion.insert(
            workspaceId: workspaceId,
            userId: userId,
            rootPk: rootPk,
            // A high-water mark, so a later read of an older record is a
            // rollback rather than a quiet downgrade.
            highestEscrowVersionSeen: escrowVersion > seen ? escrowVersion : seen,
            pinnedAt: _now(),
          ),
        );
  }

  // --- Capture --------------------------------------------------------------

  /// Author an op: mint its HLC, sign it, queue it, and reduce it locally.
  ///
  /// The envelope is built and signed *now*, not at send time, so `author_seq`
  /// and `prev_author_hash` record the order this device actually authored in
  /// whatever the network then does. The local reduce is optimistic and needs
  /// no server round-trip; when the op is pulled back its HLC is equal to the
  /// stored one, so re-applying it is a no-op.
  ///
  /// [keyEpoch] null — the normal case — authors at the Workspace's **current**
  /// epoch. The floor is the only record of which epoch that is in this slice
  /// (#554's rotate ops are what will raise it), so authoring at the floor is
  /// authoring at the current epoch. Hard-coding 0 here would mean the first raise
  /// bricked every content capture on the device with `keyEpochBelowFloor`, which
  /// is the opposite of what a floor is for. An explicit value is for a caller that
  /// genuinely knows the epoch it is writing under; below the floor it is refused,
  /// which is the guard doing its job rather than the client refusing its own work.
  ///
  /// **The payload is round-tripped through the receive path's own codec before
  /// anything is signed.** `frameBody → parseBody → OpPayload.decode` is byte for
  /// byte the pipeline a pull runs, so a payload no receiver could apply — a
  /// non-canonical entity id being the one that bites in practice — is a thrown
  /// `SyncRejection` at this call site with the store, the outbox and the author
  /// chain all untouched. Without it such a payload applied locally, was signed
  /// and uploaded, and was then quarantined by every peer *and* by this device's
  /// own echo: silent permanent divergence, surfacing as "did not converge" a
  /// long way from the cause (#573, Phase 0 of #553). Reusing the literal receive
  /// functions rather than a parallel check is what makes a future tightening of
  /// the codec bind authors automatically, with no second site to update.
  ///
  /// The decoded payload then goes through `Reducer.guardPayload` — the receive
  /// path's own stateless refusals, the same method on the same instance rather
  /// than an author-side copy. The reducer runs it again inside `apply`; running
  /// it here is what puts it *before* the op is durable, so a payload every peer
  /// (and this device's own echo) would quarantine — a `user_preferences` value
  /// write naming no key being the case with a golden vector — never reaches the
  /// outbox. Both validations sit ahead of authoring for the same reason.
  ///
  /// Both run *before* `_authorAndQueue`, and therefore before the
  /// `keyEpochBelowFloor` guard: a stale-epoch capture that is also wire-invalid
  /// reports `malformed_payload`, which is intended — wire validity is the earlier
  /// question, and the answer is the same on every device regardless of its state.
  ///
  /// The **decoded** payload is what gets reduced. That is a structural guarantee
  /// rather than a behavioural change: the author applies the exact object every
  /// peer will construct from the signed bytes, so no codec asymmetry that decode
  /// *accepts* can split this device's state from its peers'.
  Future<String> capture({
    required String collection,
    required String entityId,
    Map<String, Object?> fields = const {},
    bool tombstone = false,
    int? keyEpoch,
    Hlc? clock,
  }) async {
    final payload = OpPayload(
      collection: collection,
      entityId: entityId,
      hlc: clock ?? _clock.send(),
      fields: {
        for (final entry in fields.entries) entry.key: FieldWrite(entry.value),
      },
      tombstone: tombstone,
    );
    final wireBytes = payload.encode();
    final decoded = OpPayload.decode(parseBody(frameBody(wireBytes)));
    _reducer.guardPayload(decoded, authorMemberIdHex: identity.memberIdHex);
    final opId = await _authorAndQueue(
      opClass: opClassContent,
      payload: wireBytes,
      keyEpoch: keyEpoch ?? await epochFloor(),
    );
    final affected =
        await _reducer.apply(decoded, authorMemberIdHex: identity.memberIdHex);
    // The authoring device projects its own op too: that is what applies the
    // widened cascade and the `focus_session_tasks.id` realignment locally,
    // rather than leaving the author as the one device whose rows differ.
    //
    // **No reconcile here**, deliberately: a local write went through
    // `TagDao.findOrCreateTag`, which cannot mint a duplicate `(name, type)`, so
    // there is nothing to fold — and this is the recursion site, since the fold's
    // own ops emit back through this very method (see [DomainReconciler.reconcile]).
    await projector?.project(affected);
    return opId;
  }

  /// Author a control op. Nothing is reduced: control ops carry no content.
  ///
  /// The caller is `EnrolmentService`, which is the only thing in this slice
  /// that has a Root to sign a payload with.
  ///
  /// The bytes go through the **stateless prefix** of [_verifyControlOp], in its
  /// order — `parseBody` → `ControlPayload.decode` → `requireServedType` →
  /// `requireChainLinkShape` — for the same reason [capture] round-trips its
  /// payload, and with more at stake: a quarantined control op wedges every op
  /// chaining through it. The state-dependent stages (Root signature,
  /// certificate-binds-this-envelope, workspace match, chain position) stay
  /// receive-side deliberately. Their inputs are the *receiving* device's state —
  /// its pinned Root, its directory, its applied control log, the pulled envelope
  /// — so re-implementing them here would create a second verification path free
  /// to disagree with the first, which is the failure this validation exists to
  /// remove. The certificates themselves are minted and Root-signed moments
  /// earlier by the same code that verifies them.
  ///
  /// `async` and not an arrow: a refusal has to reach the caller as a *failed
  /// future*, the way [capture]'s does, rather than as a synchronous throw out of
  /// the call expression that no `.catchError` on the result could see. The body
  /// still runs to `_authorAndQueue` without an intervening `await`, so the
  /// authoring queue slot is claimed in call order exactly as before.
  Future<String> captureControl(Uint8List payload) async {
    final decoded = ControlPayload.decode(parseBody(frameBody(payload)));
    decoded.requireServedType();
    decoded.requireChainLinkShape();
    return _authorAndQueue(opClass: opClassControl, payload: payload, keyEpoch: 0);
  }

  /// Author a class-4 compaction snapshot, and self-apply it.
  ///
  /// [capture]'s discipline to the letter — round-trip the payload through the
  /// receive path's own codec, run the receive path's own guards, *then* sign — with
  /// one guard more: [guardOpClassShape] at class 4, so a snapshot whose fields do
  /// not carry their original clocks is a thrown [SyncRejection] here rather than an
  /// op every peer quarantines.
  ///
  /// **The self-apply is a provable no-op**, and this refuses if it ever is not.
  /// Every field of an honest snapshot carries the clock already stored for it, so
  /// reduction skips each one as an equal-HLC idempotent write. A snapshot that
  /// *changes* the compactor's own reduced state is a bug in whatever built it — it
  /// means the clocks are not the joined ones — and it must never be signed. The
  /// check runs *before* [_authorAndQueue], as a thrown [StateError] rather than an
  /// `assert`: an assertion is stripped from release builds and, worse, ran after
  /// the outbox row and `author_state` were already durable, so a dishonest snapshot
  /// shipped silently. Applying first is safe precisely because an honest snapshot
  /// is a no-op — nothing is undone when nothing changed — and the apply plus its
  /// before/after fingerprint check run inside one [SyncDatabase.transaction] so a
  /// *dishonest* snapshot's mutation rolls back with the throw rather than staying
  /// written until the next rebuild. The reducer's own transaction nests as a
  /// savepoint inside it; [_authorAndQueue] and projection run only once that
  /// transaction has committed the no-op.
  Future<String> captureCompaction(OpPayload snapshot) async {
    final wireBytes = snapshot.encode();
    final decoded = OpPayload.decode(parseBody(frameBody(wireBytes)));
    guardOpClassShape(decoded, opClass: opClassCompaction);
    _reducer.guardPayload(decoded, authorMemberIdHex: identity.memberIdHex);

    final affected = await _db.transaction(() async {
      final before =
          await _entityFingerprint(decoded.collection, decoded.entityId);
      final touched =
          await _reducer.apply(decoded, authorMemberIdHex: identity.memberIdHex);
      final after =
          await _entityFingerprint(decoded.collection, decoded.entityId);
      if (before != after) {
        throw StateError(
          'a compaction snapshot changed its own author\'s reduced state, so its '
          'per-field clocks are not the joined ones: $before -> $after',
        );
      }
      return touched;
    });

    final opId = await _authorAndQueue(
      opClass: opClassCompaction,
      payload: wireBytes,
      keyEpoch: await epochFloor(),
    );
    // No reconcile: the self-apply above is a *provable* no-op — this method
    // refuses the snapshot otherwise — so it changes no domain row and can create
    // no duplicate to fold.
    await projector?.project(affected);
    return opId;
  }

  /// Author a class-5 prune. Nothing is applied here — see below.
  ///
  /// The codec round-trip enforces the shape rules (non-empty, no duplicate on
  /// either key, bounded), and suite 0x00 is picked by
  /// [mustStayPlaintextOpClasses] rather than by anything this method decides.
  ///
  /// **The compactor does not insert its own attestations at authoring**, and that
  /// is deliberate rather than an omission. A `pruned_attestations` row carries the
  /// prune's transport seq, which does not exist until the server appends; the
  /// alternative was a nullable-seq special case plus an echo-time backfill. Instead
  /// the rows land when the prune's own echo comes back through the ordinary class-5
  /// receive path — one code path for every device, author included. It costs
  /// nothing (the compactor's `op_log` holds the full history, so its own verdicts
  /// never need the bridge) and it buys a self-check: the echo's cross-check runs
  /// against the very rows the attestations were minted from, so a mismatch there
  /// would be the compactor accusing itself.
  Future<String> capturePrune(PrunePayload prune) async {
    final wireBytes = prune.encode();
    // Decoded and discarded, exactly as [capture] does: what matters is that the
    // bytes survive the receiver's own codec before they are signed.
    PrunePayload.decode(parseBody(frameBody(wireBytes)));
    return _authorAndQueue(
      opClass: opClassPrune,
      payload: wireBytes,
      keyEpoch: await epochFloor(),
    );
  }

  /// One entity's reduced fields and their clocks, as one comparable string.
  ///
  /// Only [captureCompaction]'s no-op assertion reads it, which is why it is a
  /// fingerprint rather than a structured value: the question is "did anything
  /// move", and a string answers it without a second equality to maintain.
  Future<String> _entityFingerprint(String collection, String entityId) async {
    final rows = await _db.customSelect(
      'SELECT f.field AS field, f.value_json AS value_json, c.wall_ms AS wall_ms, '
      'c.counter AS counter, c.member_id_hex AS member_id_hex '
      'FROM reduced_fields f JOIN field_clocks c '
      '  ON c.collection = f.collection AND c.entity_id = f.entity_id '
      ' AND c.field = f.field '
      'WHERE f.collection = ? AND f.entity_id = ? ORDER BY f.field',
      variables: [Variable<String>(collection), Variable<String>(entityId)],
      readsFrom: {_db.reducedFields, _db.fieldClocks},
    ).get();
    final tombstone = await (_db.select(_db.rowTombstones)
          ..where((row) =>
              row.collection.equals(collection) & row.entityId.equals(entityId)))
        .getSingleOrNull();
    return [
      for (final row in rows)
        '${row.read<String>('field')}=${row.read<String>('value_json')}'
            '@${row.read<int>('wall_ms')}.${row.read<int>('counter')}'
            '.${row.read<String>('member_id_hex')}',
      if (tombstone != null)
        'tombstone@${tombstone.wallMs}.${tombstone.counter}.${tombstone.memberIdHex}',
    ].join('|');
  }

  /// The whole log including superseded rows — the **history view** (#555).
  ///
  /// A read, not a sync: the envelopes are returned and deliberately **not** fed
  /// through the receive pipeline. A device asking for history already holds the
  /// state those ops reduced to, so re-receiving them would grow the quarantine and
  /// the alarm table for no gain — and a compacted position is one the chain floor
  /// already accounts for.
  Future<List<PulledOp>> history({int since = 0}) async {
    final ops = <PulledOp>[];
    var cursor = since;
    while (true) {
      final page = await transport.pullOps(
        workspaceId,
        since: cursor,
        limit: pullPageLimit,
        includeCompacted: true,
      );
      if (page.ops.isEmpty) break;
      ops.addAll(page.ops);
      final highest = page.ops.map((op) => op.seq).reduce(max);
      // The same no-forward-progress stop `pull` uses: a server ignoring `since`
      // on a log longer than one page would otherwise page for ever.
      if (highest <= cursor) break;
      cursor = highest;
      if (!page.hasMore) break;
    }
    return ops;
  }

  /// Every logged op that writes to one entity, oldest first — the scan a
  /// compaction pass finds its targets with.
  ///
  /// Lives here rather than in `compaction.dart` because decoding a body needs the
  /// suite dispatch and the epoch keys, and both belong to this class. Control and
  /// prune ops are excluded structurally: they carry no entity write, and both are
  /// exempt from compaction anyway.
  ///
  /// A full decode-scan of the log, and accepted as such for v1: there is no entity
  /// index on `op_log`, and compaction is a rare background pass rather than
  /// something on a read path. If it ever becomes hot, an index over the decoded
  /// `(collection, entity_id)` is the fix, and this is the one call site to change.
  Future<List<LoggedEntityOp>> loggedOpsForEntity({
    required String collection,
    required String entityId,
  }) async {
    final rows = await (_db.select(_db.opLog)
          ..where((row) => row.workspaceId.equals(workspaceId))
          ..orderBy([(row) => OrderingTerm(expression: row.seq)]))
        .get();
    final matches = <LoggedEntityOp>[];
    for (final row in rows) {
      try {
        final parts = splitEnvelope(row.envelope);
        final header = OpHeader.parse(parts.header);
        if (header.opClass != opClassContent && header.opClass != opClassCompaction) {
          continue;
        }
        final payload =
            await _decodeContentPayload(header, parts.header, parts.body);
        if (payload.collection != collection || payload.entityId != entityId) {
          continue;
        }
        matches.add((
          seq: row.seq,
          authorMemberId: header.authorMemberId,
          authorSeq: header.authorSeq,
          opClass: header.opClass,
          envelope: row.envelope,
        ));
      } on SyncRejection {
        // Bytes this device can no longer read are bytes it cannot claim to be
        // superseding. Skipping them is the fail-closed answer: a prune must attest
        // what it has actually accounted for.
        continue;
      }
    }
    return matches;
  }

  /// Every logged entity op, bucketed by `(collection, entity_id)` in one scan.
  ///
  /// The compaction sweep's shape: [Compactor.compactionCandidates] weighs every
  /// entity at once, and asking [loggedOpsForEntity] per entity would re-decode the
  /// whole `op_log` once per entity — O(entities × log) full decodes on a mature
  /// store. This decodes each row once and buckets it by the decoded
  /// `(collection, entity_id)`, so the sweep costs a single scan. Same structural
  /// exclusions and the same fail-closed skip on unreadable bytes as the per-entity
  /// scan, because it is the same scan.
  Future<Map<(String, String), List<LoggedEntityOp>>> loggedOpsByEntity() async {
    final rows = await (_db.select(_db.opLog)
          ..where((row) => row.workspaceId.equals(workspaceId))
          ..orderBy([(row) => OrderingTerm(expression: row.seq)]))
        .get();
    final buckets = <(String, String), List<LoggedEntityOp>>{};
    for (final row in rows) {
      try {
        final parts = splitEnvelope(row.envelope);
        final header = OpHeader.parse(parts.header);
        if (header.opClass != opClassContent &&
            header.opClass != opClassCompaction) {
          continue;
        }
        final payload =
            await _decodeContentPayload(header, parts.header, parts.body);
        (buckets[(payload.collection, payload.entityId)] ??= []).add((
          seq: row.seq,
          authorMemberId: header.authorMemberId,
          authorSeq: header.authorSeq,
          opClass: header.opClass,
          envelope: row.envelope,
        ));
      } on SyncRejection {
        continue;
      }
    }
    return buckets;
  }

  /// Every chain position a verified prune has attested, by author.
  ///
  /// Read by the compaction pass so it never proposes a target twice, and by the
  /// floor computation. Exposed rather than kept private because #575's predicate
  /// has to measure against the same set (see [effectiveChainHeadSeq]).
  Future<List<PrunedAttestationRow>> prunedAttestations({String? authorMemberId}) =>
      (_db.select(_db.prunedAttestations)
            ..where((row) => authorMemberId == null
                ? row.workspaceId.equals(workspaceId)
                : row.workspaceId.equals(workspaceId) &
                    row.authorMemberId.equals(authorMemberId))
            ..orderBy([(row) => OrderingTerm(expression: row.authorSeq)]))
          .get();

  /// Tail of the authoring queue: every `_authorAndQueue` waits on it.
  ///
  /// The chain head is *read* by [_authorChain], the envelope is *signed*
  /// against it, and only then does a transaction advance it — so the head
  /// cannot be re-read under the write lock, and one transaction cannot cover
  /// the whole ceremony. Two `capture()`/`captureControl()` calls that are not
  /// awaited sequentially would otherwise both observe the same head and mint
  /// two signed envelopes claiming one `author_seq` with one `prev_author_hash`:
  /// a fork this device authored against itself, which the server refuses with
  /// `author_chain_conflict` and which [chainVerdict] reads as an integrity
  /// event. No constraint catches it either — `op_log`'s unique
  /// `(workspace, author, author_seq)` index guards the *receive* path, while
  /// `outbox` and `author_state` hold no such key. Serialising the ceremony is
  /// therefore what makes one slot hold one op on the authoring side.
  Future<void> _authoring = Future<void>.value();

  /// [keyEpoch] is spelled at every call site rather than defaulted: a content op
  /// that silently inherited 0 would be refused by its own author the moment the
  /// floor rose above it, and the exemption that makes 0 correct belongs to
  /// control ops alone.
  Future<String> _authorAndQueue({
    required int opClass,
    required Uint8List payload,
    required int keyEpoch,
  }) {
    final authored = _authoring.then((_) => _authorAndQueueLocked(
          opClass: opClass,
          payload: payload,
          keyEpoch: keyEpoch,
        ));
    // A refused or failed author must not wedge the queue behind it: the next
    // caller waits for this one to *finish*, not to succeed. The error still
    // reaches the caller through the future returned here.
    _authoring = authored.then<void>((_) {}, onError: (Object _) {});
    return authored;
  }

  Future<String> _authorAndQueueLocked({
    required int opClass,
    required Uint8List payload,
    required int keyEpoch,
  }) async {
    // The floor is consulted on **authoring**, which is where it bites: refusing
    // to build an envelope below it is what makes a rotation stick rather than
    // being undone by the next offline write. Control ops are exempt — a `rotate`
    // that raises the floor cannot be required to already clear it — and a content
    // op reaches here at the current epoch, so this fires only for a genuinely
    // stale epoch an explicit caller supplied.
    if (opClass != opClassControl) {
      final floor = await epochFloor();
      if (keyEpoch < floor) {
        throw SyncRejection(
          SyncRejectionReason.keyEpochBelowFloor,
          'refusing to author at key_epoch $keyEpoch, below this Workspace\'s '
          'floor of $floor',
        );
      }
    }
    // **Encryption is a fact about the epoch, not a mode this client is in.** A
    // content op is sealed iff this device holds `K_{w,keyEpoch}`, so turning
    // encryption on is the arrival of a key and nothing else — no switch, no
    // per-call flag, and no way for two ops at one epoch to disagree about the
    // suite. Control ops are `plaintext_v1` for ever (the server materialises their
    // payloads and holds no key), which is why the lookup is skipped for them
    // rather than merely expected to miss.
    // [mustStayPlaintextOpClasses] rather than a bare control test: a prune is
    // 0x00 for ever for the same reason a control op is — the server acts on the
    // payload and holds no key — so the lookup is skipped rather than merely
    // expected to miss.
    final workspaceKey = mustStayPlaintextOpClasses.contains(opClass)
        ? null
        : await workspaceKeys.keyFor(workspaceId, keyEpoch);
    if (workspaceKey == null &&
        !mustStayPlaintextOpClasses.contains(opClass) &&
        keyEpoch > 0) {
      // **A missing key is never permission to emit plaintext.** The exemption is
      // [mustStayPlaintextOpClasses], not a bare control test: a prune is 0x00 for
      // ever for the same reason a control op is, so a missing key at epoch >= 1 is
      // never its problem — forcing it through this guard would kill compaction
      // pruning on every rotated Workspace. Above epoch 0 the epoch exists only
      // because a `rotate` created it, and a rotate commits to a wrap set before it
      // is authored — so "no key at epoch >= 1" is always a delivery gap on this
      // device for a *sealed* class, never a legitimately unkeyed epoch. Sealing is
      // still a fact about the epoch rather than a mode; this is the one case where
      // the fact cannot be read off the key alone. Authoring `plaintext_v1` here
      // would put the user's content on the server in the clear at an epoch that is
      // supposed to be encrypted, and every peer holding the key would refuse it as
      // `plaintext_at_encrypted_epoch` — a silent divergence where the capture
      // looks saved locally and reaches nobody. Refusing is loud and heals: the
      // pull tail fetches the wrap and the next capture seals.
      throw SyncRejection(
        SyncRejectionReason.missingEpochKey,
        'refusing to author at key_epoch $keyEpoch without K_{w,$keyEpoch}: the '
        'epoch is keyed and this device does not hold its key yet',
      );
    }
    final chain = await _authorChain();
    final header = OpHeader(
      workspaceId: workspaceId,
      opClass: opClass,
      suite: workspaceKey == null ? suitePlaintextV1 : suiteAeadV1,
      keyEpoch: keyEpoch,
      opId: _newOpId(),
      authorMemberId: identity.memberId,
      authorKeyId: identity.keyId,
      authorSeq: chain.nextAuthorSeq,
      prevAuthorHash: chain.lastEnvelopeHash,
      // Minted here and written into the header *before* it is serialized, so the
      // AAD and the signature both cover it. Zero under 0x00, as the codec requires.
      nonce: workspaceKey == null ? null : randomBytes(_nonceEntropy, nonceBytes),
    );
    final framedBody = frameBody(payload);
    // The same 158 bytes are the AAD here and the AAD on receive: `serialize()` is
    // a pure function of the header, and `buildEnvelope` calls it again to lay the
    // envelope out, so there is one definition of those bytes rather than a copy to
    // keep in step.
    final body = workspaceKey == null
        ? framedBody
        : await sealBody(
            headerBytes: header.serialize(),
            framedBody: framedBody,
            workspaceKey: workspaceKey,
          );
    final envelope = await identity.signer.buildEnvelope(header, body);

    await _db.transaction(() async {
      await _db.into(_db.outbox).insert(
            OutboxCompanion.insert(
              workspaceId: workspaceId,
              opId: header.opId,
              authorSeq: header.authorSeq,
              envelope: envelope,
              capturedAt: _now(),
            ),
          );
      await _db.into(_db.authorState).insertOnConflictUpdate(
            AuthorStateCompanion.insert(
              workspaceId: workspaceId,
              memberId: identity.memberId,
              nextAuthorSeq: header.authorSeq + 1,
              lastEnvelopeHash: envelopeHash(envelope),
            ),
          );
    });
    return header.opId;
  }

  /// Random UUIDv4, namespaced by the author in the uniqueness key
  /// `(workspace, author, op_id)` — one member cannot burn another's op id
  /// space (review F13).
  String _newOpId() => const Uuid().v4();

  Future<({int nextAuthorSeq, Uint8List lastEnvelopeHash})> _authorChain() async {
    final state = await (_db.select(_db.authorState)
          ..where((row) =>
              row.workspaceId.equals(workspaceId) &
              row.memberId.equals(identity.memberId)))
        .getSingleOrNull();
    return (
      nextAuthorSeq: state?.nextAuthorSeq ?? 1,
      lastEnvelopeHash: state?.lastEnvelopeHash ?? Uint8List(prevAuthorHashBytes),
    );
  }

  // --- Sync -----------------------------------------------------------------

  /// Flush the outbox, then pull. A transport failure on either half leaves the
  /// queue and the cursor exactly where they were.
  ///
  /// Returns the post-sync [SyncHealth] — what the sync indicator reads.
  Future<SyncHealth> sync() async {
    await flushOutbox();
    await pull();
    return health();
  }

  /// Post everything unsent, and record a verdict when the server refuses our
  /// own history.
  ///
  /// A chain conflict is caught here and never rethrown. Single-writer-per-member
  /// means a 409 on our own POST is the server disagreeing with what it already
  /// acknowledged, and the fail-closed answer is to keep the outbox exactly as it
  /// is — re-numbering our own ops to fit the server's view would forge this
  /// device's chain. But a wedged *outbox* must never wedge the *pull*: reads keep
  /// working, and the wedge surfaces through [SyncHealth.pendingOpCount], which by
  /// construction makes `clean` false for as long as the queue is stuck.
  ///
  /// **`genesis_not_first` is the one refusal that is not a wedge and not an
  /// accusation.** It says another Root-holder founded this Workspace between our
  /// pull and our POST, which is a race the log-state-conditioned ceremony is
  /// *allowed* to lose (ADR-0031): both devices held Root, both observed an empty
  /// log, and exactly one genesis may exist. Retaining the queue here would wedge
  /// it for ever — our genesis can never become acceptable — so the staged ops go
  /// and the author chain rewinds to what the log actually acknowledges. See
  /// [_dropUnacceptedOps].
  /// The queue is posted in [maxOpsPerBatch] chunks, in `author_seq` order, each
  /// acknowledged before the next goes out. Unchunked, a device that authored
  /// more than the server's cap while offline would re-POST the same oversized
  /// batch on every `sync()`, be refused 413 `batch_too_large` every time, and
  /// never drain — a permanent outage in exactly the offline case the outbox is
  /// for. Chunking in chain order is what keeps the server seeing this author's
  /// positions in the order they were authored.
  Future<FlushOutcome> flushOutbox() async {
    final queueGeneration = _outboxQueueGeneration;
    final pending = await (_db.select(_db.outbox)
          ..where((row) => row.workspaceId.equals(workspaceId) & row.sentAt.isNull())
          ..orderBy([(row) => OrderingTerm(expression: row.authorSeq)]))
        .get();
    if (pending.isEmpty) {
      await _settleKeptOursRollback();
      return FlushOutcome.flushed;
    }

    for (var start = 0; start < pending.length; start += maxOpsPerBatch) {
      final chunk = pending.sublist(
        start,
        min(start + maxOpsPerBatch, pending.length),
      );
      // The queue was re-made since this flush read it: what is left of this
      // batch is stale, and the next flush reads the new queue.
      if (queueGeneration != _outboxQueueGeneration) return FlushOutcome.retained;
      try {
        // A duplicate result is still an acknowledgement: the server holds the op.
        await transport.postOps(workspaceId, [for (final row in chunk) row.envelope]);
      } on AuthorChainConflictException catch (conflict) {
        // A refusal for a queue that was re-made mid-flight is stale: it names
        // a position in the old queue, and raising on it could wipe the
        // decision that re-made the queue. The next flush asks again.
        if (queueGeneration != _outboxQueueGeneration) return FlushOutcome.retained;
        await _recordOwnWritesVerdict(conflict, queueGeneration: queueGeneration);
        return FlushOutcome.retained;
      } on SyncTransportException catch (refusal) {
        if (refusal.code != genesisNotFirstCode) rethrow;
        // Genesis sits at the head of the queue, so everything still unsent is
        // queued behind it and goes with it — not just this chunk.
        await _dropUnacceptedOps(pending.sublist(start));
        return FlushOutcome.genesisSuperseded;
      }
      // An acknowledgement for the old queue does not count toward the new one.
      if (queueGeneration != _outboxQueueGeneration) return FlushOutcome.retained;
      await _markSent(chunk);
    }
    await _settleKeptOursRollback();
    return FlushOutcome.flushed;
  }

  /// Resolve the rollback alarm the User settled by keeping this device's own
  /// writes, now that the server has acknowledged the upload.
  ///
  /// **The decision and the resolution are two moments.** The decision is the
  /// User's answer, recorded the moment they answer it; the resolution is the
  /// server acknowledging the re-send that answer asked for. The alarm stands
  /// in between — decided, unresolved, and reported — because the accusation
  /// has not been answered by the server yet.
  ///
  /// Only an alarm the User answered with *keep ours*, and only this member's
  /// own rollback, is settled here. A re-send the server refuses again goes
  /// down the refusal path instead, which re-raises the alarm and takes the
  /// decision with it.
  ///
  /// **The settlement is tied to the re-send, not to the flush that happens to
  /// be running.** A flush that read its queue before the User answered carries
  /// the queued write and not the re-send the answer asked for; if it settled
  /// the accusation, the accusation would be closed over bytes the server has
  /// never been sent. So the accusation is settled only when every row from
  /// the agreed position onwards has been sent — the re-send acknowledged.
  Future<void> _settleKeptOursRollback() async {
    final decided = await (_db.select(_db.integrityAlarms)
          ..where((row) =>
              row.workspaceId.equals(workspaceId) &
              row.kind.equals(IntegrityAlarmKind.ownWritesRollback.code) &
              row.authorMemberId.equals(identity.memberId) &
              row.resolution.equals(AlarmResolution.keptOurs.code) &
              row.resolvedAt.isNull()))
        .get();
    if (decided.isEmpty) return;
    final now = _now();
    for (final alarm in decided) {
      final from = alarm.repostFromAuthorSeq;
      // No agreed position means no re-send to wait for: the accusation was
      // answered, and there is nothing this flush could acknowledge.
      if (from == null) continue;
      await (_db.update(_db.integrityAlarms)
            ..where((row) =>
                row.id.equals(alarm.id) &
                row.resolvedAt.isNull() &
                // The decision and the position it was taken at, guarded with the
                // rest of the statement: a flush that re-raised the accusation
                // behind this settlement's back has cleared the decision and
                // moved the agreed position, and the answer the User gave was
                // about the smaller accusation. The occurrence count says the
                // same thing the other way round — a re-raise means the
                // accusation has grown since the User was asked.
                row.resolution.equals(AlarmResolution.keptOurs.code) &
                row.occurrenceCount.equals(alarm.occurrenceCount) &
                row.repostFromAuthorSeq.equals(from) &
                _noUnsentOutboxRowFrom(from)))
          .write(IntegrityAlarmsCompanion(resolvedAt: Value(now)));
    }
  }

  /// No outbox row from [from] onwards is still waiting to be sent.
  ///
  /// The re-send the User asked for runs from the position the server and this
  /// device last agreed on, so every row from there onwards is part of it: the
  /// accusation is settled when the last of them has been acknowledged, and not
  /// before.
  Expression<bool> _noUnsentOutboxRowFrom(int from) => notExistsQuery(
        _db.select(_db.outbox)
          ..where((row) =>
              row.workspaceId.equals(workspaceId) &
              row.authorSeq.isBiggerOrEqualValue(from) &
              row.sentAt.isNull()),
      );

  /// Stamp one acknowledged chunk in a single UPDATE.
  Future<void> _markSent(List<OutboxRow> acknowledged) =>
      (_db.update(_db.outbox)
            ..where((row) => row.id.isIn([for (final row in acknowledged) row.id])))
          .write(OutboxCompanion(sentAt: Value(_now())));

  /// Drop this Workspace's unsent control ops, and rewind the author chain to
  /// the head the log attests.
  ///
  /// **The caller's rows are the only ones dropped.** Two callers, one routine:
  /// a genesis the race is already lost (the flush's case) and an enrolment that
  /// was interrupted before its registration reached the server
  /// ([discardUnsentControlOps]'s case). Both are the same fact: the batch was
  /// never accepted, so the positions its rows claim are unspent.
  ///
  /// **This is not the outbox being edited as evidence.** The outbox is authored
  /// truth about what the *server holds* — that is what the own-writes comparison
  /// reads it for — and none of these rows were accepted: the batch failed whole,
  /// so the positions they claim are unspent. Keeping them would leave the queue
  /// re-posting a genesis that can never be accepted, and leave the author chain
  /// numbered past a slot the server still says is free, which is the second half
  /// of the wedge: the register that has to follow *must* be this author's op 1.
  ///
  /// So the chain is rewound to the head the **log** attests rather than to a
  /// remembered number — after a pull that is the winner's view of us, which for
  /// a device that has just lost a founding race is nothing at all.
  ///
  /// No alarm. A lost race is two honest devices doing the same correct thing.
  Future<void> _dropUnacceptedOps(List<OutboxRow> superseded) async {
    // Read the re-derived head *before* the transaction, so clearing `authorState`
    // and rewriting it are one atomic step. The head derives from `op_log`, which
    // this transaction does not touch, so reading it first is safe — whereas a
    // crash between a separate clear and a separate rewrite would leave the device
    // with no `authorState` at all, and `_authorChain` would then report
    // `nextAuthorSeq: 1` under the zero hash while the log still holds this
    // author's earlier positions: the next op authored would claim a spent slot.
    //
    // Whatever of ours the log *does* hold still owns its positions, so the
    // rewind is a re-derivation and not a reset to one.
    final head = await _chainHead(identity.memberId);
    await _db.transaction(() async {
      for (final row in superseded) {
        await (_db.delete(_db.outbox)..where((r) => r.id.equals(row.id))).go();
      }
      await (_db.delete(_db.authorState)
            ..where((row) =>
                row.workspaceId.equals(workspaceId) &
                row.memberId.equals(identity.memberId)))
          .go();
      // Left cleared when the log attests no head — a device that has just lost a
      // founding race has nothing of its own in the winner's view of the log.
      if (head != null) {
        await _db.into(_db.authorState).insertOnConflictUpdate(
              AuthorStateCompanion.insert(
                workspaceId: workspaceId,
                memberId: identity.memberId,
                nextAuthorSeq: head.authorSeq + 1,
                lastEnvelopeHash: head.envelopeHash,
              ),
            );
      }
    });
  }

  /// Drop this Workspace's unsent **control** ops, and rewind the author chain
  /// to the head the log attests.
  ///
  /// The case is an enrolment that was interrupted before its registration
  /// reached the server: the queue still holds the registration the server has
  /// never seen, and re-authoring one behind it would claim an author position
  /// the log says is free while the queue says otherwise. Dropping the queued
  /// rows and re-authoring against the freshly pulled head is what keeps the
  /// chain honest — and the head is the log's, not a remembered number.
  ///
  /// **Only control ops are ever dropped.** A queued content op is the user's
  /// own work, and discarding it is not this call's business: every unsent row
  /// is read first, and the call refuses rather than deleting anything if one
  /// of them is not a control op.
  Future<void> discardUnsentControlOps() async {
    final pending = await (_db.select(_db.outbox)
          ..where((row) => row.workspaceId.equals(workspaceId) & row.sentAt.isNull())
          ..orderBy([(row) => OrderingTerm(expression: row.authorSeq)]))
        .get();
    if (pending.isEmpty) return;
    for (final row in pending) {
      final header = OpHeader.parse(row.envelope);
      if (header.opClass != opClassControl) {
        throw StateError(
          'refusing to discard unsent op ${header.opId}: it is a content op, '
          'and only control ops may be dropped',
        );
      }
    }
    await _dropUnacceptedOps(pending);
  }

  /// The own-writes verdict on one refused POST.
  ///
  /// The client cannot distinguish a server that rolled our writes back from a
  /// device restored off an older local backup, so the detail names both. The
  /// response is identical either way — retain the outbox, re-number nothing —
  /// and un-wedging is an operator action that needs the user in the loop.
  ///
  /// Three outcomes raise `own_writes_rollback`: the server expects a position
  /// at or below the acknowledged head (carries the repost position), beyond
  /// anything this device authored, or more than one past the acknowledged head
  /// (the last two carry none). Anything else raises nothing.
  ///
  /// **The verdict is one transaction with the generation check inside it.**
  /// Keep-ours also runs in a transaction and bumps [_outboxQueueGeneration]
  /// at its end, so the two serialize: a verdict either runs wholly before
  /// keep-ours (which then finds the accusation changed and refuses) or wholly
  /// after it (and sees the new generation and records nothing). A check made
  /// before the reads would leave a window in which keep-ours lands between
  /// the reads and the alarm write, and re-raising clears its decision.
  Future<void> _recordOwnWritesVerdict(
    AuthorChainConflictException conflict, {
    required int queueGeneration,
  }) async {
    await _db.transaction(() async {
      if (queueGeneration != _outboxQueueGeneration) return;
      await _recordOwnWritesVerdictWithin(conflict);
    });
  }

  Future<void> _recordOwnWritesVerdictWithin(
    AuthorChainConflictException conflict,
  ) async {
    final expected = conflict.expectedAuthorSeq;
    if (expected == null) {
      // The race-retry path resolves a raced insert without being able to name a
      // position. That is an ordinary transient conflict, not evidence of
      // anything: no alarm, outbox retained, next sync retries.
      return;
    }
    final acknowledged = await _acknowledgedAuthorSeq();
    final authored = (await _authorChain()).nextAuthorSeq - 1;
    if (expected <= acknowledged) {
      await _raiseAlarm(
        IntegrityAlarmKind.ownWritesRollback,
        authorMemberId: identity.memberId,
        // The position the server and this device last agreed on: everything
        // from here up was acknowledged and is now gone from the server. That
        // is where this device's writes can be put back, so the alarm carries
        // it — a rollback the User answers by keeping its own work needs to
        // know where to start.
        repostFromAuthorSeq: expected,
        detail: 'the server expects author_seq $expected, at or below the '
            '$acknowledged it has already acknowledged — either it rolled this '
            "device's writes back, or this device was restored from an older "
            'local backup and the server is honest. The outbox is retained and '
            'nothing is re-numbered.',
      );
      return;
    }
    if (expected > authored + 1) {
      await _raiseAlarm(
        IntegrityAlarmKind.ownWritesRollback,
        authorMemberId: identity.memberId,
        detail: 'the server expects author_seq $expected, beyond the $authored '
            'this device has ever authored — something may be authoring under '
            "this device's key.",
      );
      return;
    }
    // Between the two: the server holds a position this device never sent, but
    // this device has authored past it. A re-post of an op the server already
    // holds is answered as a duplicate before the position check, so a refusal
    // more than one past the acknowledged head means the server holds, under
    // this device's key, an op this outbox never sent. Exactly one past
    // (`acknowledged + 1`) stays silent: a flush that read its queue before a
    // *keep ours* answer is refused at precisely the first unsent position, and
    // the next flush settles it.
    if (expected > acknowledged + 1) {
      await _raiseAlarm(
        IntegrityAlarmKind.ownWritesRollback,
        authorMemberId: identity.memberId,
        detail: 'the server expects author_seq $expected, past the '
            '$acknowledged it has acknowledged from this device, and this '
            'device never sent the positions in between — something may be '
            "authoring under this device's key, or this device was restored "
            'from an older local backup. The outbox is retained and nothing is '
            're-numbered.',
      );
    }
  }

  /// The highest position of ours the server has acknowledged holding.
  Future<int> _acknowledgedAuthorSeq() async {
    final rows = await (_db.select(_db.outbox)
          ..where((row) => row.workspaceId.equals(workspaceId) & row.sentAt.isNotNull())
          ..orderBy([
            (row) => OrderingTerm(expression: row.authorSeq, mode: OrderingMode.desc),
          ])
          ..limit(1))
        .get();
    return rows.isEmpty ? 0 : rows.first.authorSeq;
  }

  /// Pull from the cursor, refusing any regression of it.
  ///
  /// Two rules, and the boundary between them is load-bearing:
  ///
  /// * **Staleness is judged against the `since` this page asked with**, not
  ///   against the cursor as it moves through the page. `since` is a pure client
  ///   parameter, so an op at or below it is something an honest server cannot
  ///   serve. An op *above* it that arrives out of order is a reorder, which is a
  ///   different accusation and heals — judging it against a cursor already
  ///   dragged forward by a later op in the same page would refuse the very
  ///   predecessor that unlocks the rest.
  /// * **The cursor only ever moves forward**, so a reordered page leaves it at
  ///   the highest seq the page carried.
  ///
  /// A page that produces **no forward progress at all ends the pull** — without
  /// that rule a server ignoring `since` on a log longer than one page would keep
  /// `has_more` true against a pinned cursor forever.
  ///
  /// **One pull at a time** — see [_pullInFlight]. A caller that arrives while a
  /// pull is running waits for that pull and for one more after it, rather than
  /// fetching the same ops a second time.
  Future<void> pull() {
    final inFlight = _pullInFlight;
    if (inFlight != null) {
      // A pull is already running. Ask for one more after it — the op this
      // caller cares about may have landed after the running pull fetched its
      // page — and wait for that one instead of racing this one.
      _pullQueued = true;
      return inFlight;
    }
    final completer = Completer<void>();
    _pullInFlight = completer.future;
    unawaited(_runPulls(completer));
    return completer.future;
  }

  /// Run the pull until no further pull is asked for, and settle [completer].
  ///
  /// The loop is the same shape the signal listener's own single-flight uses:
  /// a pull that arrives mid-run is not dropped but coalesced into one more
  /// run, so a burst of pokes costs a bounded number of round-trips rather
  /// than one per poke.
  ///
  /// The failure of a run is the failure of every caller waiting on it: a
  /// transport error leaves the cursor where it was, and the next pull retries
  /// from there.
  Future<void> _runPulls(Completer<void> completer) async {
    try {
      do {
        _pullQueued = false;
        await _pullOnce();
      } while (_pullQueued);
    } catch (error, stackTrace) {
      _pullInFlight = null;
      completer.completeError(error, stackTrace);
      return;
    }
    _pullInFlight = null;
    completer.complete();
  }

  /// One pull, from the cursor to the end of the pages it fetched.
  Future<void> _pullOnce() async {
    var cursor = await _cursor();
    var hasMore = true;
    final affected = <AffectedEntity>{};
    while (hasMore) {
      final since = cursor;
      final page = await transport.pullOps(
        workspaceId,
        since: since,
        limit: pullPageLimit,
      );
      var advanced = false;
      for (final pulled in page.ops) {
        if (pulled.seq <= since) {
          await _refuseStaleServe(pulled, since);
          continue;
        }
        affected.addAll(await _receive(pulled));
        if (pulled.seq > cursor) {
          cursor = pulled.seq;
          await _saveCursor(cursor);
          advanced = true;
        }
      }
      hasMore = page.hasMore && page.ops.isNotEmpty && advanced;
    }
    // A change this device refused for an author key it did not know is
    // re-examined once it knows that key. The gate is the directory's
    // signing-key count: it runs on the first pull after any launch (the count
    // is unknown then) and on a pull that learned a key, and on no other pull,
    // so a standing stranger row costs nothing.
    //
    // Placed first on the tail so that whatever a re-received op sets in
    // motion — a `missing_epoch_key` refusal, a raised epoch floor,
    // the stored rebuild marker — is picked up by the blocks below in the same pull.
    //
    // A control op refused because its predecessor was not applied yet is
    // re-examined once the applied control head has moved (or on the first pull
    // after a launch). The two refusals feed each other — an unchained revoke
    // re-admitted below moves the head, which lets the registration refused
    // behind it in, which teaches a key, which lets that device's unchained grant
    // in — so the two scans run in one loop until neither has anything new to
    // look at. It terminates: each gate value is read *before* its scan and only
    // changes when a scan admits a row, an admitted row is stamped released and
    // leaves both scans' sets, and the rows are finite.
    while (true) {
      var scanned = false;
      final knownSigningKeyCount = directory.knownSigningKeyCount;
      if (knownSigningKeyCount != _knownSigningKeyCountAtLastUnchainedScan) {
        affected.addAll(await _releaseOpsAwaitingMemberRegistration());
        // Stored only after the scan returns, so a storage fault mid-scan — or a
        // key learned during it — re-arms the next pull.
        _knownSigningKeyCountAtLastUnchainedScan = knownSigningKeyCount;
        scanned = true;
      }
      final appliedControlHead = await _appliedControlHeadState();
      final headAtLastScan = _appliedControlHeadAtLastBreakScan;
      if (headAtLastScan == null || !_sameAppliedControlHead(appliedControlHead, headAtLastScan)) {
        affected.addAll(await _releaseOpsAwaitingControlPredecessor());
        _appliedControlHeadAtLastBreakScan = appliedControlHead;
        scanned = true;
      }
      if (!scanned) break;
    }
    // A rotation landed, or something is still waiting on a wrap. Either way the
    // fetch is bounded — one round-trip per pull, never one per op — and the
    // freshness race F14b names (the wraps PUT landing moments after the rotate op)
    // resolves on the next pull rather than as a mystery decryption failure.
    //
    // The third trigger is the state-based one: this device is at a keyed epoch
    // it does not hold the key for. The flag is memory, so a device that exited
    // between a rotate applying and its fetch comes back without it, and with
    // nothing quarantined to fetch on either — see [_lacksCurrentEpochKey].
    if (_epochKeyRefreshRequired ||
        await _hasOpsAwaitingEpochKeys() ||
        await _lacksCurrentEpochKey()) {
      await refreshEpochKeys();
      // Cleared only once the fetch has actually happened. A rotate can raise this
      // flag while nothing is quarantined yet — no content at the new epoch has
      // arrived — so clearing it before a fetch that then fails on transport would
      // leave neither the flag nor a quarantine row to trigger the next attempt,
      // and this device would sit keyless at a keyed epoch until unrelated traffic
      // happened to quarantine something.
      _epochKeyRefreshRequired = false;
      // Unconditional on what the fetch learned: a key can also have arrived through
      // the escrow path (an enrolling device adopting the history), and gating the
      // release on *this* fetch having learned something would leave those ops
      // quarantined for ever.
      affected.addAll(await _releaseOpsAwaitingEpochKeys());
    }
    // A rotate raised the floor this pull, so ops quarantined at an epoch that is
    // now established can be released. Placed **after** the key-refresh block above
    // so that when a rotate and its wrap both landed this pull, the key is already
    // remembered before the future-epoch op is re-received. Gated so a pull that
    // applied no floor-raising rotate *and* holds nothing quarantined skips the scan
    // entirely — the re-examination churn AC-4 forbids. The state-based half
    // ([_hasOpsAwaitingEpoch], mirroring [_hasOpsAwaitingEpochKeys]) is the
    // restart-safe fallback: a device torn down after a rotate durably raised the
    // floor but before this scan ran would otherwise lose the transient flag and
    // strand the quarantined op until some unrelated later rotation re-armed it.
    if (_epochFloorRaised || await _hasOpsAwaitingEpoch()) {
      affected.addAll(await _releaseOpsAwaitingEpoch());
      _epochFloorRaised = false;
    }
    // A chain-successor replay was interrupted by a storage fault mid-release,
    // so the winner is a claimant again but the cursor has long since moved past
    // its transport seq — the server will not re-serve it, and re-serving its
    // predecessor does not re-run the scan (the predecessor is already logged).
    // Re-arm the scan here, on the same shape as the epoch re-arm above: the
    // transient flag catches the same-session retry, and the durable
    // `release_started_at` marker ([_hasInterruptedChainReplay]) is the
    // restart-safe fallback across process death. Gated so a pull that
    // interrupted nothing *and* holds no marked row skips the scan — a standing
    // fork never carries the marker, so this re-runs for interrupted replays
    // only and re-raises no fork alarm (AC-4).
    if (_chainSuccessorReplayRetryRequired ||
        await _hasInterruptedChainReplay()) {
      _chainSuccessorReplayRetryRequired = false;
      for (final author in await _authorsWithInterruptedChainReplay()) {
        affected.addAll(await _releaseChainSuccessors(author));
      }
    }
    // A verdict-changing event (a resolved control fork, a late control op, a
    // newly learned epoch key) stored a marker when it happened, so the obligation
    // survives a restart and a rebuild that throws. The marker is cleared below,
    // only after the projection of what the rebuild changed (#1032).
    final rebuildRequiredSince = await _rebuildRequiredSince();
    if (rebuildRequiredSince != null) {
      // The authorization verdicts the content ops applied under are no longer
      // the right ones.
      affected.addAll(await rebuildFromOpLog());
    }
    // Keep the whole batch durable until projection succeeds, including entities
    // removed by the rebuild. An empty pull (or a new client) must retry them.
    if (projector != null) await _recordAwaitingProjection(affected);
    final toRelease = _releaseAfterRebuild.toList();
    // Projection is the tail of the receive order, one pass per batch: an
    // entity touched by three ops in one pull is projected once, from the
    // reduced state all three produced. It reads the durable record of reduced
    // entities as well as this pull's own set, so a change reduced by a pull that
    // later failed is projected by this one (#1031). The recorded rows are
    // deleted only after `project` returns.
    final recorded = projector == null
        ? const <AffectedEntity>{}
        : await _entitiesAwaitingProjection();
    affected.addAll(recorded);
    final touched = await projector?.project(affected);
    // A late control op still owes both its rebuild and projection until this
    // point. Its unreleased row re-arms the rebuild after a process exit.
    for (final rowId in toRelease) {
      await _markReleased(rowId);
      _releaseAfterRebuild.remove(rowId);
    }
    if (recorded.isNotEmpty) await _clearAwaitingProjection(recorded);
    if (rebuildRequiredSince != null) {
      await _clearRebuildRequirement(rebuildRequiredSince);
    }
    // And the convergence passes run on what it changed. This is the route by
    // which a peer's Tag entity first reaches the domain store, so it is where a
    // duplicate `(name, type)` group is folded and a junction stranded on a
    // tombstoned tag is rehomed. Outside any transaction, and never on the author
    // path — see [DomainReconciler.reconcile].
    if (touched != null) await _reconcileProjected(touched);
    // A decision whose projection never reached the screen is still work to be
    // done, and a pull that brings nothing new is enough to do it: the change
    // is in the reduced state, and the recovery puts it back on the screen.
    await _recoverUnprojectedResolutions();
    await _stampPullCompleted();
  }

  /// Record [entities] as reduced and not yet projected, in this Workspace.
  Future<void> _recordAwaitingProjection(Set<AffectedEntity> entities) async {
    for (final entity in entities) {
      await _db.into(_db.entitiesAwaitingProjection).insert(
            EntitiesAwaitingProjectionCompanion.insert(
              workspaceId: workspaceId,
              collection: entity.collection,
              entityId: entity.entityId,
            ),
            mode: InsertMode.insertOrIgnore,
          );
    }
  }

  /// The entities this Workspace reduced and has not yet projected.
  Future<Set<AffectedEntity>> _entitiesAwaitingProjection() async {
    final rows = await (_db.select(_db.entitiesAwaitingProjection)
          ..where((row) => row.workspaceId.equals(workspaceId)))
        .get();
    return {
      for (final row in rows)
        (collection: row.collection, entityId: row.entityId),
    };
  }

  /// Delete exactly the rows [projected] names — by key, never the whole table,
  /// so a row recorded while projection ran stays.
  Future<void> _clearAwaitingProjection(Set<AffectedEntity> projected) async {
    await _db.transaction(() async {
      for (final entity in projected) {
        await (_db.delete(_db.entitiesAwaitingProjection)
              ..where((row) =>
                  row.workspaceId.equals(workspaceId) &
                  row.collection.equals(entity.collection) &
                  row.entityId.equals(entity.entityId)))
            .go();
      }
    });
  }

  /// Run the convergence passes over what this batch projected, and **contain any
  /// failure to the passes themselves**.
  ///
  /// By the time this runs the batch is finished: every op is durable, the cursor
  /// has advanced, and the projection has committed. The reconcile is a *repair*
  /// layered on top of that, not a step of applying the batch — so a fold or
  /// rehome that throws must not take [_stampPullCompleted] down with it. Letting
  /// it propagate would be #605's own defect reintroduced with a new thrower:
  /// ops durable, cursor advanced past the batch, completion never stamped, and
  /// the server never asked for those seqs again.
  ///
  /// So the failure is swallowed and re-armed. Retrying is safe because both
  /// passes are idempotent and both detect from **durable** state — a duplicate
  /// `(name, type)` group and a junction whose `tag_id` has no row — rather than
  /// from the batch. Re-running them finds the same work, and finds nothing once
  /// it is done.
  ///
  /// [_reconcileRetryRequired] exists because the *gate* is batch-derived even
  /// though the work is not: a later pull carrying no tag op would skip the passes
  /// and leave the repair waiting on unrelated traffic. The flag forces one run.
  ///
  /// It is in-memory only, and that is the honest bound rather than an oversight:
  /// losing it to a restart delays the repair to the next tag-touching pull or the
  /// next `rebuildDomainFromOpLog`, both of which re-detect from scratch. Unlike
  /// the hole #605 names, nothing here becomes unreachable — the evidence is the
  /// duplicate row itself, and it does not go away.
  Future<void> _reconcileProjected(Set<String> touched) async {
    final pending = reconciler;
    if (pending == null) return;
    try {
      await pending.reconcile(touched, force: _reconcileRetryRequired);
      _reconcileRetryRequired = false;
    } catch (_) {
      _reconcileRetryRequired = true;
    }
  }

  /// Clear this Workspace's derived state and replay its retained log,
  /// recomputing **only** the authorization verdict.
  ///
  /// **Scoped to the collections this Workspace owns** ([ownsCollection]): the
  /// other Workspace on the Device shares the merge tables, and its log is not
  /// replayed here, so wiping its state would lose it (and delete its domain rows
  /// in the same pull).
  ///
  /// The honest mechanism behind "re-verdict content after a fork resolution".
  /// The reduced substrate is a join-semilattice with **no per-seq lineage**, so
  /// there is no such thing as discarding reduced state back to a seq: the only
  /// correct move is a full rebuild. Every retained envelope (#546) is replayed
  /// through the shipped reducer (#550) in seq order.
  ///
  /// One rule bounds the replay: **reducer-guard refusals are honoured from the
  /// persisted `refusedReason` (#551), never re-evaluated.** Replaying an
  /// `hlc_in_the_future` refusal hours later would flip the answer and diverge
  /// devices — the exact failure `refusedReason` exists to prevent. Only
  /// `no_live_grant` is recomputed, because that is the verdict the fork changed.
  ///
  /// **Idempotent**: running it twice from the same winning chain is a no-op, so
  /// the recovery path can never oscillate. #555 inherits this entry point, since
  /// compaction needs the same one and must keep it correct under pruning.
  ///
  /// This is the replay only. Owing it, and clearing what is owed, is the pull
  /// tail's job: the stored marker stays set until the rebuild **and** the
  /// projection of what it changed have finished, so a throw part-way leaves it
  /// owed (#1032).
  ///
  /// **Entities the rebuild *un*-reduces are surfaced too**, which is the whole
  /// reason [_reducedEntities] is read before the wipe. An entity whose every op
  /// became refused reduces to nothing, so the replay never names it — and a
  /// projector told only about what re-applied would leave its domain row
  /// standing as the last visible trace of a quarantined branch. The pre-wipe set
  /// is unioned into the return value, so such an entity reaches
  /// [DomainProjector.project] with no live field and is deleted there.
  ///
  /// The pre-wipe set is the *reduced* state's memory of the entity, and the
  /// reduced state is wiped before the replay — so a rebuild that threw leaves
  /// the next rebuild with nothing to read it from. The op log is the evidence
  /// that outlives the wipe: an op that was applied and that the corrected view
  /// now refuses names its entity here, so the entity reaches the projector
  /// either way.
  Future<Set<AffectedEntity>> rebuildFromOpLog() async {
    final rows = await (_db.select(_db.opLog)
          ..where((row) => row.workspaceId.equals(workspaceId))
          ..orderBy([(row) => OrderingTerm(expression: row.seq)]))
        .get();

    // Read before the wipe: after it there is no way to tell an entity that
    // reduced to nothing from one this device never held.
    final reducedBefore = {
      for (final entity in await _reducedEntities())
        if (ownsCollection(entity.collection)) entity,
    };

    // Merge state whose winning clock is this device's own node id was never an
    // op: the log cannot rebuild it, and wiping it would make the projector delete
    // rows the user wrote. Saved here, merged back after the replay.
    final carriedAcrossRebuild = [
      for (final change in await host?.changesStampedByDevice() ?? const <Change>[])
        if (ownsCollection(change.collection)) change,
    ];

    // Derived state only. The op log, the outbox, the applied control log and the
    // quarantine are all evidence, and evidence is not edited.
    await _db.transaction(() async {
      // Once wiped, an entity removed by replay cannot be rediscovered from
      // reduced state. Queue it atomically with the wipe for projection retry.
      if (projector != null) await _recordAwaitingProjection(reducedBefore);
      final preferences = isPreferencesWorkspace;
      Expression<bool> owned(GeneratedColumn<String> collection) => preferences
          ? collection.equals(userPreferencesCollection)
          : collection.equals(userPreferencesCollection).not();
      await (_db.delete(_db.reducedFields)..where((row) => owned(row.collection))).go();
      await (_db.delete(_db.fieldClocks)..where((row) => owned(row.collection))).go();
      await (_db.delete(_db.rowTombstones)..where((row) => owned(row.collection))).go();
    });

    final view = await grantsView();
    final affected = <AffectedEntity>{};
    for (final row in rows) {
      final OpHeader header;
      final OpPayload payload;
      try {
        final parts = splitEnvelope(row.envelope);
        header = OpHeader.parse(parts.header);
        // Neither class reduces to anything. A control op carries no content; a
        // prune's effect is `pruned_attestations`, which is *evidence* and so is not
        // among the derived tables the wipe above cleared — replaying it would
        // re-insert rows that never went away.
        if (header.opClass == opClassControl || header.opClass == opClassPrune) {
          continue;
        }
        // The **same** dispatch the receive path uses, and not a second decode: a
        // rebuild that ran `parseBody` on an `aead_v1` body would find every
        // encrypted row unparseable and quietly un-reduce the entire Workspace.
        payload = await _decodeContentPayload(header, parts.header, parts.body);
        guardOpClassShape(payload, opClass: header.opClass);
      } on SyncRejection catch (rejection) {
        if (rejection.reason == SyncRejectionReason.missingEpochKey) {
          // A row skipped for a key this device does not yet hold is a delivery
          // gap, not unparseable bytes: without this flag a rebuild during the
          // post-rotation window would silently un-reduce the new epoch's
          // content until an unrelated event forced another rebuild. The pull
          // tail sees the flag and heals it once the wrap arrives.
          _epochKeyRefreshRequired = true;
        }
        // Bytes that no longer parse cannot be re-applied, and the row stays as
        // the evidence it is. Refusing to replay it is the fail-closed answer.
        continue;
      }

      final refused = row.refusedReason;
      if (refused != null && refused != SyncRejectionReason.noLiveGrant.code) {
        // A reducer-guard refusal: honoured verbatim, never re-evaluated.
        continue;
      }
      // The question "did the User refuse these bytes for good?" and everything
      // that follows from the answer happen in one transaction. A rejection is
      // recorded in a transaction too, so the two are serialized: if the
      // rejection lands first the change is skipped; if the admission lands
      // first the refusal is released, and the rejection finds nothing left to
      // cover.
      await _db.transaction(() async {
        if (refused != null && await _refusedForGood(row)) {
          // The User refused this change for good, and the log still carries
          // the verdict that refused it. A replay is not a second chance at the
          // User's decision: however the authorization question comes out this
          // time, these bytes are not applied.
          return;
        }

        final authorization = view.verdictFor(
          authorMemberId: header.authorMemberId,
          opClass: header.opClass,
          seq: row.seq,
        );
        if (authorization != null) {
          await _stampRefused(row.seq, authorization.reason);
          // An op that was applied and is now refused loses its place in the
          // reduced state, and the entity it belonged to has to be re-surfaced
          // so the projector hears of the removal. The pre-wipe reduced state
          // names that entity — but only while it still holds it, and a rebuild
          // that threw has already wiped it. The op log is the evidence that
          // outlives the wipe, so the entity is named from there: `applied_at`
          // says the op was applied, and the corrected view says it no longer
          // may be.
          if (row.appliedAt != null && ownsCollection(payload.collection)) {
            affected.add((
              collection: payload.collection,
              entityId: payload.entityId,
            ));
          }
          return;
        }
        try {
          affected.addAll(await _reducer.apply(
            payload,
            authorMemberIdHex: memberIdToHex(header.authorMemberId),
          ));
          // Newly authorized by the corrected view: clear the stale refusal so
          // the row stops claiming a verdict that no longer stands.
          if (refused != null) {
            await _clearRefused(row.seq);
            await _retireAdmittedRefusal(row, header.authorMemberId);
          }
          await _stampApplied(row.seq);
        } on SyncRejection catch (rejection) {
          // A guard that fires on a *fresh* evaluation is recorded as it was
          // the first time; the clock is not re-consulted for anything already
          // judged.
          await _stampRefused(row.seq, rejection.reason);
        }
      });
    }
    // A change the User took upstream is applied again here. The wipe above
    // cleared the merge state, and the log cannot rebuild it: the change was
    // never logged, because it was refused. Only the changes the User has
    // answered for, and only while they are still held, are re-applied — in the
    // order they arrived in, so the merge sees them the way it saw them before.
    final takenUpstream = await (_db.select(_db.quarantinedOps)
          ..where((row) =>
              row.workspaceId.equals(workspaceId) &
              row.resolution.equals(AlarmResolution.tookUpstream.code) &
              row.releasedAt.isNull())
          ..orderBy([(row) => OrderingTerm(expression: row.seq)]))
        .get();
    for (final row in takenUpstream) {
      affected.addAll(await _applyHeldChange(row));
    }
    if (carriedAcrossRebuild.isNotEmpty) {
      await host!.restore(carriedAcrossRebuild);
    }
    // Everything that *was* reduced, whether or not it reduced again: an entity
    // whose ops all became refused is exactly the case the projector has to hear
    // about, and it is the one the replay above can never name.
    return affected..addAll(reducedBefore);
  }

  /// Every entity the reduced substrate currently holds any trace of — see the
  /// top-level [reducedEntities], which the first-open domain rebuild shares.
  Future<Set<AffectedEntity>> _reducedEntities() => reducedEntities(_db);

  /// A rebuild admitted a change the log had refused for want of a Grant.
  ///
  /// The refusal no longer stands, so neither does the offer to refuse it for
  /// good: offering it would close the accusation over a change that is
  /// applied, and no later rebuild would check the decision. The held copy is
  /// kept as evidence and marked released, like any refusal the world has
  /// answered, and the accusation is closed once nothing it covers is left.
  /// A refusal the User already decided is not touched.
  Future<void> _retireAdmittedRefusal(OpLogRow row, String? author) async {
    final held = await (_db.select(_db.quarantinedOps)
          ..where((r) =>
              r.workspaceId.equals(workspaceId) &
              r.seq.equals(row.seq) &
              r.reason.equals(SyncRejectionReason.noLiveGrant.code) &
              r.releasedAt.isNull() &
              r.resolution.isNull()))
        .get();
    for (final r in held) {
      if (sameBytes(r.envelope, row.envelope)) await _markReleased(r.id);
    }
    final kind = alarmForRejection(SyncRejectionReason.noLiveGrant);
    if (kind == null) return;
    final alarm = await _standingAlarm(kind, author);
    if (alarm == null) return;
    if ((await _rowsCoveredByAlarm(alarm, kind)).isEmpty) {
      await _resolveAlarm(kind, author);
    }
  }

  Future<void> _clearRefused(int seq) async {
    await (_db.update(_db.opLog)
          ..where((row) => row.workspaceId.equals(workspaceId) & row.seq.equals(seq)))
        .write(const OpLogCompanion(refusedReason: Value(null)));
  }

  /// Whether the User refused this exact change for good.
  ///
  /// The decision is recorded on the refused change, and the log keeps only the
  /// verdict that refused it. A rebuild re-asks the authorization question for
  /// a refusal whose verdict depended on the grants view — and the answer can
  /// change: a corrected control branch can authorize a change that was
  /// refused for want of a Grant, which is how an op ends up applied and
  /// un-refused by a rebuild. **A change the User has already refused for good
  /// is not one of those.**
  ///
  /// The bytes have to match. One position can carry different bytes, and only
  /// the bytes that were refused were refused.
  Future<bool> _refusedForGood(OpLogRow row) async {
    final reason = row.refusedReason;
    if (reason == null) return false;
    final refused = await (_db.select(_db.quarantinedOps)
          ..where((r) =>
              r.workspaceId.equals(workspaceId) &
              r.seq.equals(row.seq) &
              r.reason.equals(reason) &
              r.releasedAt.isNull() &
              r.resolution.equals(AlarmResolution.rejectedPermanently.code)))
        .get();
    return refused.any((r) => sameBytes(r.envelope, row.envelope));
  }

  /// A served op at or below the `since` it was asked past: alarm, and refuse it
  /// without applying.
  ///
  /// The alarm fires whatever the bytes are, because the *serving* is the
  /// accusation — and it fires **once per served op**, however many accusations
  /// those bytes then attract. What the bytes are decides how much more there is
  /// to say: the op we already hold at that seq is nothing further, and anything
  /// else is a second claim on a slot this device has spent — refused rather
  /// than written over, because the log is evidence and evidence is not edited.
  Future<void> _refuseStaleServe(PulledOp pulled, int since) async {
    OpHeader? header;
    try {
      header = OpHeader.parse(splitEnvelope(pulled.envelope).header);
    } on SyncRejection {
      header = null;
    }
    final servedDetail = 'seq ${pulled.seq} was served for a pull since $since';
    final stored = await (_db.select(_db.opLog)
          ..where((row) => row.workspaceId.equals(workspaceId) & row.seq.equals(pulled.seq)))
        .getSingleOrNull();
    if (stored != null && sameBytes(stored.envelope, pulled.envelope)) {
      // Bytes we already hold: the serving is the whole accusation, and there is
      // no envelope to quarantine.
      await _raiseAlarm(
        IntegrityAlarmKind.stalePrefixServed,
        authorMemberId: header?.authorMemberId,
        detail: servedDetail,
      );
      return;
    }

    var rejection = SyncRejection(
      SyncRejectionReason.staleReplayedOp,
      'seq ${pulled.seq} is at or below the since $since it was served for, and '
      'is not what this device holds there',
    );
    if (header != null) {
      // The chain rules still have their own say: a *different* op claiming a
      // position this author's chain already holds is a rewrite, and filing it
      // under the transport-level code alone would lose that accusation.
      final verdict = await _chainVerdictFor(header, pulled.envelope);
      if (verdict.isRefusal) rejection = verdict.rejection!;
    }
    await _refuse(
      pulled,
      rejection,
      header,
      servingAccusation: (
        kind: IntegrityAlarmKind.stalePrefixServed,
        detail: servedDetail,
      ),
    );
  }

  /// The fail-closed receive pipeline, in its normative order.
  ///
  /// `backend/tests/sync/test_envelope_vectors.py` runs the same sequence
  /// against the same negative vectors, so the two stay in step. A refusal
  /// quarantines the op and the stream continues: one bad op from a server
  /// must not be able to stall a device.
  ///
  /// [reclaimRefusedControlSlot] is set only by
  /// [_releaseOpsAwaitingControlPredecessor]. A control op refused at the
  /// position check is *logged-but-refused*, so its `op_log` slot is taken by its
  /// own bytes and [_logReceived] would treat a second receipt as a re-serve and
  /// skip it. With the flag, the control branch takes that slot back instead —
  /// see [_reclaimRefusedControlSlot] — and every check after it runs unchanged.
  ///
  /// [onRefused] is told the refusal the op ended in, when it ended in one.
  /// [_releaseOpsAwaitingControlPredecessor] needs it: the `op_log` slot cannot
  /// always say what the re-examination decided, because a refusal raised
  /// **before** the transaction — a signature, a certificate, a grant, an
  /// authority — leaves the slot holding the verdict that refused the op the
  /// first time. The verdict is told here rather than read back, because it is
  /// the verdict this receive reached.
  Future<Set<AffectedEntity>> _receive(
    PulledOp pulled, {
    bool reclaimRefusedControlSlot = false,
    void Function(SyncRejection refusal)? onRefused,
  }) async {
    OpHeader? header;
    try {
      final parts = splitEnvelope(pulled.envelope);
      header = OpHeader.parse(parts.header);
      header.checkServed();
      if (header.workspaceId != workspaceId) {
        // Not a filtered row: a header disagreeing with the stream it arrived
        // in is a server-integrity event (review F6).
        throw SyncRejection(
          SyncRejectionReason.workspaceMismatch,
          'envelope names workspace ${header.workspaceId}, pulled from $workspaceId',
        );
      }

      if (header.opClass == opClassControl) {
        // Verify, **then** log, **then** apply — the content path's order, for the
        // content path's reasons. Logging before verifying would let a server burn
        // an honest author's chain slots with bytes that never verified; applying
        // before logging lands authority effects with no `op_log` row behind them,
        // so a server spending one transport `seq` on two chain-valid control ops
        // gets the second one's authority with nothing for a later content op to
        // chain to. A taken slot ends the op here, without applying anything.
        // A non-nullable capture: `header` is a nullable field, so its promotion
        // at the branch guard above does not carry into the transaction closure.
        final controlHeader = header;
        final verified = await _verifyControlOp(pulled, parts.body, header);
        // Log, apply and stamp as **one** transaction, so a crash mid-apply leaves
        // either all of it or none — never a raised epoch floor with no
        // applied-control record, nor an `op_log` row claiming an apply that never
        // completed (#618). `_db` is a [SyncDatabase], so `transaction()` is the
        // ordinary drift transaction the reducer already nests as a savepoint;
        // `_verifyControlOp` above has no side effects and stays outside it.
        SyncRejection? refused;
        RegistrationCertificate? learned;
        final logged = await _db.transaction(() async {
          // A taken slot ends the op here. On an own-reserve re-serve [_logReceived]
          // wrote nothing and returns false; on a genuine collision it wrote the
          // alarm and returns false. Returning normally (never throwing) commits
          // either way — the alarm, when there is one, must persist.
          final slotClaimed = reclaimRefusedControlSlot
              ? await _reclaimRefusedControlSlot(pulled)
              : await _logReceived(pulled, controlHeader);
          if (!slotClaimed) return false;
          try {
            learned = await _applyControlOp(pulled, controlHeader, verified);
          } on SyncRejection catch (rejection) {
            // Logged-but-refused (#551), the same shape the content path uses: the
            // envelope stays as chain evidence, no authority effect landed, and the
            // row records which guard fired. The stamp commits *with* the log row;
            // the rejection is rethrown *outside* the transaction (below) so the
            // outer catch still quarantines and accuses.
            await _stampRefused(pulled.seq, rejection.reason);
            refused = rejection;
            return true;
          }
          // `applied_at` is stamped only now — after verification and application
          // both succeeded — so a refused control op is logged-but-unapplied
          // evidence rather than a row claiming an apply that never happened.
          await _stampApplied(pulled.seq);
          return true;
        });
        // A genuine storage fault inside the body rolls the whole unit back and
        // propagates out here (caught by the outer `on SqliteException`); only a
        // refusal or a taken slot returns normally.
        if (refused != null) throw refused!;
        if (!logged) return const {};
        // The op taught this device a chained key. Remembered **after** the commit
        // and **only** on the committed, non-refused path, so a `controlChainFork`
        // throw (which never sets `learned`) never remembers one, and no in-memory
        // key outlives a durable record that rolled back.
        if (learned != null) directory.rememberChained(learned!);
        // A control op reduces to nothing, so it contributes no projection work; it
        // is logged because later content ops from the same author chain to it.
        return const {};
      }

      if (header.opClass == opClassPrune) {
        // The other class whose payload this device *reads* rather than reduces,
        // and the only one that can move another author's chain floor. Its own
        // pipeline, because what it does at the end is insert evidence rather than
        // apply a write — everything before that is the content path's order.
        return await _receivePrune(pulled, parts.body, header);
      }

      final signPk = directory.publicKeyFor(header.authorMemberId, header.authorKeyId);
      await verifyEnvelope(pulled.envelope, signPk);
      // Verify, **then** decrypt. Ed25519 authenticates the author over
      // `header || body`; the AEAD then authenticates the header binding and yields
      // the plaintext. The other order would have this device decrypting bytes no
      // registered key vouched for.
      final payload = await _decodeContentPayload(header, parts.header, parts.body);
      // Class 4 reduces through the same reducer as class 1 — the per-field-HLC
      // machinery already existed for it — so the only new thing on the way in is
      // the shape guard, and it sits between decode and apply exactly as every
      // other payload-semantics rule does.
      guardOpClassShape(payload, opClass: header.opClass);

      final verdict = await _chainVerdictFor(header, pulled.envelope);
      if (verdict.isRefusal) throw verdict.rejection!;
      await _checkOwnWrites(header, pulled.envelope);
      if (verdict.outcome != ChainOutcome.accept) {
        // Already held byte for byte, or a pruned original re-served with the bytes
        // a verified prune attested. Nothing to log, nothing to re-apply, and
        // nothing to accuse: the cursor moves on.
        return const {};
      }

      // Log, authorise, reduce and stamp as **one** transaction, the shape the
      // control and prune branches already use (#618). Run as separate statements,
      // a storage fault inside the reducer left the `op_log` row committed with
      // the cursor unmoved: the re-serve then stopped at "already held" and the op
      // was never reduced (#1031). Rolled back together, the re-serve takes the
      // ordinary path. `_refuse` (quarantine row, alarm) and the chain-successor
      // scan stay **after** the commit, as in the control branch; `_stampRefused`
      // is part of the receipt and commits with the log row.
      // `header` is reassigned above, so a closure sees it as nullable; bind the
      // parsed, non-null value once.
      final contentHeader = header;
      SyncRejection? refused;
      var affected = const <AffectedEntity>{};
      final logged = await _db.transaction(() async {
        if (!await _logReceived(pulled, contentHeader)) return false;

        // The authorization stage, between the chain verdict and the reducer
        // guards. Evaluated at the op's *own* server seq, never against current
        // control state — see [GrantsView]. A refusal here is #551's
        // logged-but-refused class: the row above is already written and advances
        // per-author accounting, so an honest successor is never falsely gapped.
        final authorization = (await grantsView()).verdictFor(
          authorMemberId: contentHeader.authorMemberId,
          opClass: contentHeader.opClass,
          seq: pulled.seq,
        );
        if (authorization != null) {
          await _stampRefused(pulled.seq, authorization.reason);
          refused = authorization;
          return true;
        }

        try {
          affected = await _reducer.apply(
            payload,
            authorMemberIdHex: memberIdToHex(contentHeader.authorMemberId),
          );
          await _stampApplied(pulled.seq);
          // Recorded with the reduction, so a pull that fails before its
          // projection tail still projects this entity on the next pull.
          await _recordAwaitingProjection(affected);
        } on SyncRejection catch (rejection) {
          // Logged-but-refused: the envelope is chain evidence and stays, the
          // payload never applies, and the row records which guard fired.
          await _stampRefused(pulled.seq, rejection.reason);
          refused = rejection;
        }
        return true;
      });
      if (!logged) return const {};
      if (refused != null) {
        await _refuse(pulled, refused!, contentHeader);
      } else {
        // After the commit, so a rolled-back apply never advances the clock.
        _clock.receive(payload.hlc);
      }
      // The head advanced either way, so a quarantined successor may now be valid.
      return {
        ...affected,
        ...await _releaseChainSuccessors(contentHeader.authorMemberId),
      };
    } on SyncRejection catch (rejection) {
      // The verdict this op reached, for the caller that asked for it. Every
      // refusal ends here — the ones raised while verifying, before the
      // transaction, and the ones raised while applying, after it.
      onRefused?.call(rejection);
      await _refuse(pulled, rejection, header);
      return const {};
    } on SqliteException {
      // Storage failures keep [_logReceived]'s contract: a transient
      // `SQLITE_BUSY` is an op the next sync retries with the cursor unmoved,
      // never one skipped for ever under a refusal label it did not earn. This
      // is about *our* database, not about the envelope.
      rethrow;
    } catch (error) {
      // The fail-closed guarantee has to be total, not best-effort. Anything
      // else escaping the pipeline un-classified — a parse, verify or decode
      // path throwing something that is not a `SyncRejection` — would otherwise
      // propagate out of `pull()` before the cursor advances, so every later
      // pull refetches the same op and throws on it again: one adversarial
      // envelope, an indefinitely wedged receive. Quarantining under
      // `unexpected_receive_failure` keeps the op unapplied and surfaced while
      // the stream moves on, exactly as a named refusal does.
      await _refuse(
        pulled,
        SyncRejection(SyncRejectionReason.unexpectedReceiveFailure, '$error'),
        header,
      );
      return const {};
    }
  }

  // --- Prune ops, and the chain floor they bridge (#555) -----------------------

  /// The attestations of a class-5 op **currently being judged**, before it is
  /// applied and its rows exist.
  ///
  /// Held on the instance rather than threaded through every call because the whole
  /// pre-judgement pass — the verdict, the release scan it triggers, and the nested
  /// [_receive] of every claimant that scan re-admits — has to see the same set. A
  /// parameter would have to be forwarded through all three, and the one that
  /// forgot would silently refuse the op.
  ///
  /// **Why a prune needs to bridge with its own payload at all.** In the v1
  /// single-user fleet the owner device self-compacts, so a prune sits *above* the
  /// holes it attests in its own author chain. Judged against stored attestations
  /// alone it would be an `author_chain_gap` for ever, and nothing would ever apply
  /// it to create those attestations — a deadlock in exactly the shape the design
  /// prescribes. Admitting it on its own signed, per-position, hash-linked
  /// enumeration is what breaks that, and it concedes nothing: every position the
  /// bridge steps over is either in the log or individually attested, and every
  /// claimant the pre-pass releases is still hash-checked against its predecessor.
  PrunePayload? _provisionalPrune;

  /// Receive one class-5 op: the content pipeline, then evidence instead of a write.
  ///
  /// The pipeline is the content one and deliberately not a subset of it —
  /// signature, chain verdict, [_checkOwnWrites], `op_log`, then the authorization
  /// verdict at the op's own seq. A prune moves other authors' chain floors, so a
  /// forged or unauthorized one must get no further than any other op would.
  Future<Set<AffectedEntity>> _receivePrune(
    PulledOp pulled,
    Uint8List body,
    OpHeader header,
  ) async {
    await verifyEnvelope(
      pulled.envelope,
      directory.publicKeyFor(header.authorMemberId, header.authorKeyId),
    );
    final prune = PrunePayload.decode(parseBody(body));

    final outerProvisional = _provisionalPrune;
    _provisionalPrune = prune;
    final ChainVerdict verdict;
    try {
      var judged = await _chainVerdictFor(header, pulled.envelope);
      if (judged.isRefusal &&
          judged.rejection!.reason == SyncRejectionReason.authorChainGap) {
        // The self-compaction case: this prune's own position sits above holes only
        // this prune attests. Bridge with its payload, let the survivors between the
        // head and here become chain-valid, and ask once more. Bounded to one retry
        // — the scan runs to fixpoint, so a second attempt would learn nothing new.
        await _releaseChainSuccessors(
          header.authorMemberId,
          attestationBridged: true,
        );
        judged = await _chainVerdictFor(header, pulled.envelope);
      }
      verdict = judged;
    } finally {
      _provisionalPrune = outerProvisional;
    }
    if (verdict.isRefusal) throw verdict.rejection!;
    await _checkOwnWrites(header, pulled.envelope);
    if (verdict.outcome != ChainOutcome.accept) return const {};

    // Log, then either refuse-and-stamp or apply-and-stamp, as **one**
    // transaction: a crash between the attestation inserts and the stamp leaves
    // the evidence and the stamp all-or-nothing, never an orphan `op_log` row
    // (#618). The release scan re-enters [_receive] (which opens its own
    // transaction), so it stays **outside** this unit — below.
    SyncRejection? authorizationRefusal;
    final logged = await _db.transaction(() async {
      if (!await _logReceived(pulled, header)) return false;
      final authorization = (await grantsView()).verdictFor(
        authorMemberId: header.authorMemberId,
        opClass: header.opClass,
        seq: pulled.seq,
      );
      if (authorization != null) {
        await _stampRefused(pulled.seq, authorization.reason);
        authorizationRefusal = authorization;
        return true;
      }
      await _applyPrune(pulled.seq, prune);
      await _stampApplied(pulled.seq);
      return true;
    });
    if (!logged) return const {};
    if (authorizationRefusal != null) {
      // Quarantined **outside** the unit, mirroring the control path (#618): a
      // storage fault raised by `_refuse`'s own insert must not roll back the
      // log-and-stamp row this transaction just committed.
      await _refuse(pulled, authorizationRefusal!, header);
      // The chain head advanced, so a quarantined successor may now be valid.
      return _releaseChainSuccessors(header.authorMemberId);
    }

    // The scan runs for **every author this prune attests**, not just its own: the
    // floor it just raised is what makes those authors' quarantined survivors
    // chain-valid, and nothing else would ever ask.
    final affected = <AffectedEntity>{};
    for (final author in {header.authorMemberId, ...prune.attestedAuthors}) {
      affected.addAll(
        await _releaseChainSuccessors(author, attestationBridged: true),
      );
      // Re-asked even when the scan released nothing: a settlement in [_applyPrune]
      // can empty the unreleased set on its own, and the gap alarm has to notice.
      //
      // **And only once nothing is still waiting to be put on screen.** The
      // prune's attestation settles the claimant, but it does not put the change
      // on the User's screen: a *take upstream* whose projection failed is still
      // work to be done, and the accusation stays standing until it is done.
      // The same rule the chain release follows applies here — closing the alarm
      // would leave the change reduced but unseen, with nothing left to ask
      // about.
      if (!await _hasUnreleasedGap(author) &&
          !await _hasUnprojectedTakeUpstream(author)) {
        await _resolveAlarm(IntegrityAlarmKind.authorChainGap, author);
      }
    }
    return affected;
  }

  /// Insert what a verified prune attested, and cross-check it against what this
  /// device already holds.
  ///
  /// Three steps per attested position, and the order matters:
  ///
  /// 1. **Insert the row** — evidence of what a signed op said, and never edited. A
  ///    position already attested with *different* bytes keeps the first row and
  ///    earns an accusation: two prunes cannot both be right about one position.
  /// 2. **Cross-check `op_log`.** A stored row whose hash differs is a device
  ///    holding the originals catching a lying compactor. A matching one is the
  ///    full-history case and there is nothing to do.
  /// 3. **Cross-check `quarantined_ops`.** A gap claimant at the position whose
  ///    bytes match is the genuine op caught in the quarantine-before-prune race —
  ///    released *without* re-receiving it, because its content is superseded by the
  ///    snapshot and the position is now below the effective head. No alarm: the
  ///    claimant and the compactor agree byte for byte, and a gap row exists only
  ///    after `verifyEnvelope` passed. A claimant whose bytes *differ* stays
  ///    quarantined and stands accused.
  Future<void> _applyPrune(int pruneSeq, PrunePayload prune) async {
    for (final target in prune.targets) {
      final existing = await (_db.select(_db.prunedAttestations)
            ..where((row) =>
                row.workspaceId.equals(workspaceId) &
                row.authorMemberId.equals(target.authorMemberId) &
                row.authorSeq.equals(target.authorSeq)))
          .getSingleOrNull();
      if (existing == null) {
        await _db.into(_db.prunedAttestations).insert(
              PrunedAttestationsCompanion.insert(
                workspaceId: workspaceId,
                authorMemberId: target.authorMemberId,
                authorSeq: target.authorSeq,
                envelopeHash: target.envelopeHash,
                pruneSeq: pruneSeq,
              ),
            );
      } else if (!sameBytes(existing.envelopeHash, target.envelopeHash)) {
        await _raiseAlarm(
          IntegrityAlarmKind.pruneAttestationDivergence,
          authorMemberId: target.authorMemberId,
          detail: 'the prune at seq $pruneSeq attests author_seq '
              '${target.authorSeq} with bytes the prune at seq '
              '${existing.pruneSeq} attested differently',
        );
        continue;
      }

      final stored =
          await _storedAtAuthorSeq(target.authorMemberId, target.authorSeq);
      if (stored != null) {
        if (!sameBytes(envelopeHash(stored.envelope), target.envelopeHash)) {
          await _raiseAlarm(
            IntegrityAlarmKind.pruneAttestationDivergence,
            authorMemberId: target.authorMemberId,
            detail: 'the prune at seq $pruneSeq attests author_seq '
                '${target.authorSeq} with bytes this device does not hold there',
          );
        }
        // Agreement with the log needs nothing further, and disagreement is already
        // an accusation: either way there is no claimant question to ask, because
        // the position is settled by evidence stronger than a quarantine row.
        continue;
      }

      for (final claimant in await _quarantinedGapClaimantsAt(
        target.authorMemberId,
        target.authorSeq,
      )) {
        if (sameBytes(envelopeHash(claimant.envelope), target.envelopeHash)) {
          await _markReleased(claimant.id);
        } else {
          await _raiseAlarm(
            IntegrityAlarmKind.pruneAttestationDivergence,
            authorMemberId: target.authorMemberId,
            detail: 'a quarantined claimant at author_seq ${target.authorSeq} '
                'is not the op the prune at seq $pruneSeq attested there; both '
                'bear real signatures, so either the author forked its own chain '
                'or the compactor attested a fabrication',
            quarantineOpRowId: claimant.id,
          );
        }
      }
    }
  }

  /// The highest position of one author's chain this device can account for.
  ///
  /// `max(derived head, bridged floor)`, factored as one function because **#575
  /// has to measure against this number rather than the raw derived head**: #555
  /// widens what "settled" means, and a predicate that excluded gap rows at or
  /// below the raw head would half-work on a compacted Workspace.
  Future<int> effectiveChainHeadSeq(String authorMemberId) async {
    final head = await _chainHead(authorMemberId);
    final floor = await _bridgedChainFloor(authorMemberId, head: head);
    return max(head?.authorSeq ?? 0, floor?.seq ?? 0);
  }

  /// One author's attested positions and the verified chain floor they bridge, in
  /// a single `pruned_attestations` fetch.
  ///
  /// `attested` maps each attested `author_seq` to its envelope hash, **stored
  /// rows first**: they have already been cross-checked against this device's own
  /// evidence, so a provisional prune's target only fills a position no stored row
  /// covers (`putIfAbsent`). `floor` is the end of the contiguous run of attested
  /// positions starting just above the derived head, or null when nothing bridges.
  ///
  /// Contiguity is the whole safety argument for the floor: it never skips a
  /// position, so every step above the real head is individually attested and
  /// hash-linked. The walk needs no `op_log` lookups because the derived head *is*
  /// the highest logged position, so nothing above it is in the log by definition.
  ///
  /// Both a verdict's floor and its stored-attestation-at-a-position answer come
  /// out of the one map, so `_chainVerdictFor` reads the table once per op rather
  /// than twice (#621).
  Future<({VerifiedChainFloor? floor, Map<int, Uint8List> attested})>
      _attestedPositions(
    String authorMemberId, {
    required AuthorChainHead? head,
  }) async {
    final attested = <int, Uint8List>{
      for (final row in await prunedAttestations(authorMemberId: authorMemberId))
        row.authorSeq: row.envelopeHash,
    };
    for (final target in _provisionalPrune?.targetsOf(authorMemberId) ??
        const <PruneTarget>[]) {
      // Stored rows win: they have already been cross-checked against this device's
      // own evidence, and a provisional one has not.
      attested.putIfAbsent(target.authorSeq, () => target.envelopeHash);
    }
    if (attested.isEmpty) return (floor: null, attested: attested);

    var seq = head?.authorSeq ?? 0;
    Uint8List? hash;
    while (attested.containsKey(seq + 1)) {
      seq += 1;
      hash = attested[seq];
    }
    return (
      floor: hash == null ? null : (seq: seq, envelopeHash: hash),
      attested: attested,
    );
  }

  /// The verified chain floor for one author — the floor half of
  /// [_attestedPositions], kept as a named entry point for [effectiveChainHeadSeq]
  /// (and so the hot release-scan path reads only the floor it needs).
  Future<VerifiedChainFloor?> _bridgedChainFloor(
    String authorMemberId, {
    required AuthorChainHead? head,
  }) async =>
      (await _attestedPositions(authorMemberId, head: head)).floor;

  // --- Per-author chain enforcement -------------------------------------------

  /// The chain rules, against what this device's log already holds.
  Future<ChainVerdict> _chainVerdictFor(OpHeader header, Uint8List envelope) async {
    final head = await _chainHead(header.authorMemberId);
    // One `pruned_attestations` fetch answers both the floor and the
    // stored-attestation lookups (#621). The map is built stored-rows-first, so
    // reading `attested[authorSeq]` preserves the stored-over-provisional
    // precedence the two separate queries had.
    final positions = await _attestedPositions(header.authorMemberId, head: head);
    return chainVerdict(
      header: header,
      envelope: envelope,
      head: head,
      storedAtAuthorSeq: await _storedAtAuthorSeq(
        header.authorMemberId,
        header.authorSeq,
      ),
      storedUnderOpId: await _storedUnderOpId(header.authorMemberId, header.opId),
      // The seam #551 left dormant, now live: a verified prune is the only thing
      // that can supply a floor, and the floor wins above the derived head so a
      // mid-chain hole is bridgeable rather than a permanent gap.
      verifiedFloor: positions.floor,
      storedAttestation: positions.attested.containsKey(header.authorSeq)
          ? (
              authorSeq: header.authorSeq,
              envelopeHash: positions.attested[header.authorSeq]!,
            )
          : null,
    );
  }

  /// One author's verified head, derived from the log rather than stored.
  Future<AuthorChainHead?> _chainHead(String authorMemberId) async {
    final rows = await (_db.select(_db.opLog)
          ..where((row) =>
              row.workspaceId.equals(workspaceId) &
              row.authorMemberId.equals(authorMemberId))
          ..orderBy([
            (row) => OrderingTerm(expression: row.authorSeq, mode: OrderingMode.desc),
          ])
          ..limit(1))
        .get();
    if (rows.isEmpty) return null;
    return (
      authorSeq: rows.first.authorSeq,
      envelopeHash: envelopeHash(rows.first.envelope),
    );
  }

  Future<StoredChainOp?> _storedAtAuthorSeq(String authorMemberId, int authorSeq) async {
    final row = await (_db.select(_db.opLog)
          ..where((r) =>
              r.workspaceId.equals(workspaceId) &
              r.authorMemberId.equals(authorMemberId) &
              r.authorSeq.equals(authorSeq)))
        .getSingleOrNull();
    return row == null ? null : (authorSeq: row.authorSeq, envelope: row.envelope);
  }

  Future<StoredChainOp?> _storedUnderOpId(String authorMemberId, String opId) async {
    final row = await (_db.select(_db.opLog)
          ..where((r) =>
              r.workspaceId.equals(workspaceId) &
              r.authorMemberId.equals(authorMemberId) &
              r.opId.equals(opId)))
        .getSingleOrNull();
    return row == null ? null : (authorSeq: row.authorSeq, envelope: row.envelope);
  }

  /// Compare an envelope this device authored against the outbox row it was
  /// signed into.
  ///
  /// The outbox is retained after acknowledgement precisely for this: it is the
  /// *authored* truth, and the pull is the *received* view, so comparing them is
  /// the whole own-writes check. A substituted register needs no equivalent —
  /// step 4 of the control verification checks the envelope signature against the
  /// certificate's own key, so a stranger cannot wear our registration.
  Future<void> _checkOwnWrites(OpHeader header, Uint8List envelope) async {
    if (header.authorMemberId != identity.memberId) return;
    final authored = await (_db.select(_db.outbox)
          ..where((row) =>
              row.workspaceId.equals(workspaceId) &
              row.authorSeq.equals(header.authorSeq)))
        .getSingleOrNull();
    // No local record of authoring at that position: nothing to compare, and an
    // accusation needs a comparison.
    if (authored == null) return;
    if (sameBytes(authored.envelope, envelope)) return;
    throw SyncRejection(
      SyncRejectionReason.ownWritesDivergence,
      'the server served this device\'s own author_seq ${header.authorSeq} with '
      'different bytes than the outbox holds; the local copy stands',
    );
  }

  /// Re-admit quarantined successors, all claimants at head + 1 at a time, to
  /// fixpoint.
  ///
  /// Reorder heals; drop and fork do not, and that is what makes the three end in
  /// distinct surfaced states. Arrival order 3, 2, 1 converges in a single sync
  /// because every accepted op re-asks the same question — *which quarantined
  /// envelopes claim head + 1, and does one of them chain to the head?* — and a
  /// hostile 500-op reorder is 500 iterations of one flat loop rather than 500
  /// recursive frames.
  ///
  /// Several envelopes can claim one position, so the winner is chosen by
  /// **verification and not by arrival order**: the quarantine row id records who
  /// the server served first, and the server is the party under suspicion. A
  /// forged alternate quarantined before the genuine op arrives must not outrank
  /// it by winning a race it controls, and the head's envelope hash is the only
  /// tiebreak the attacker cannot forge. Every claimant that refuses is accused
  /// and stays refused; exactly one verifying claimant is released.
  ///
  /// Two byte-different claimants that both verify cannot happen without the
  /// author signing two continuations of its own chain — a gap row exists only
  /// after `verifyEnvelope` passed, so both bear the author's own signature. The
  /// lowest row id wins deterministically and every further verifying claimant is
  /// accused as `author_chain_fork` here, in the pass that saw it. Leaving it to
  /// the head passing the contested position and the server re-serving the loser
  /// as `author_chain_rewrite` would rest a real fork on a re-serve the server
  /// chooses whether to make: the evidence is already local, so the accusation is
  /// raised from it. Byte-identical claimants are one op quarantined under two
  /// transport seqs and accuse nobody.
  ///
  /// A genuine drop leaves `author_chain_gap` standing forever, which is correct:
  /// withholding is detectable, not preventable.
  ///
  /// [attestationBridged] suppresses the reorder accusation. A prune raising an
  /// author's floor makes that author's quarantined survivors chain-valid, and a
  /// documented compaction shape is not a server accused of shuffling a stream —
  /// which is what `author_stream_reordered` says. The gap alarm still resolves the
  /// same way, on there being no unreleased gap row left.
  Future<Set<AffectedEntity>> _releaseChainSuccessors(
    String authorMemberId, {
    bool attestationBridged = false,
  }) async {
    // Per author, not one global flag: a prune raises several authors' floors at
    // once, so a scan for one must be able to trigger a scan for another. A nested
    // scan of the *same* author is still suppressed — the outer loop re-asks the
    // same question anyway, and recursing would turn a hostile 500-op reorder into
    // 500 stack frames.
    if (_releasingChainOfAuthors.contains(authorMemberId)) return const {};
    _releasingChainOfAuthors.add(authorMemberId);
    final affected = <AffectedEntity>{};
    var releasedAny = false;
    try {
      while (true) {
        // The **effective** head, so the scan looks just above the highest position
        // this device can account for rather than just above the highest it holds.
        // On a compacted chain those differ by every hole a prune attested.
        final claimants = await _quarantinedGapClaimantsAt(
          authorMemberId,
          await effectiveChainHeadSeq(authorMemberId) + 1,
        );
        if (claimants.isEmpty) break;

        QuarantineRow? winner;
        for (final claimant in claimants) {
          // No transport seq to re-receive under, so there is nothing to release
          // even if it would verify.
          if (claimant.seq == null) continue;
          final OpHeader header;
          try {
            header = OpHeader.parse(splitEnvelope(claimant.envelope).header);
          } on SyncRejection {
            // A gap refusal implies a header that parsed, so this is unreachable;
            // skipping the claimant is still the only safe answer if it ever is not.
            continue;
          }
          final verdict = await _chainVerdictFor(header, claimant.envelope);
          if (!verdict.isRefusal) {
            if (winner == null) {
              // First verifying claimant in row-id order; the rest of the loop is
              // still walked so every other claimant gets its accusation.
              winner = claimant;
            } else if (!sameBytes(winner.envelope, claimant.envelope)) {
              // A second set of bytes chaining to the same head, under the same
              // author signature the gap row already proved: the author forked its
              // own chain. Only one of them can be released, so the other is
              // accused now rather than silently dropped — the loop will never look
              // at this position again once the head moves past it.
              await _raiseAlarm(
                IntegrityAlarmKind.authorChainFork,
                authorMemberId: authorMemberId,
                detail: 'author_seq ${header.authorSeq} has a second claimant '
                    'that also chains to the head: the author signed two '
                    'continuations of its own chain and only one was released',
                quarantineOpRowId: claimant.id,
              );
            }
            continue;
          }
          // The missing predecessor arrived and this claimant provably does not
          // chain to it: two incompatible continuations claim one position. It
          // stays quarantined — the predecessor is here, and it is not the one
          // this op was chained to. The alarm upserts by `(workspace, kind,
          // author)` and keeps the first `quarantine_op_row_id` it saw, so N
          // refusing claimants raise one row whose occurrence count grows; the
          // row id names the first claimant accused, never the whole set.
          await _raiseAlarm(
            verdict.rejection!.reason == SyncRejectionReason.prevAuthorHashMismatch
                ? IntegrityAlarmKind.authorChainFork
                : verdict.alarm!,
            authorMemberId: authorMemberId,
            detail: 'author_seq ${header.authorSeq} did not become chain-valid '
                'when its predecessor arrived: ${verdict.rejection!.message}',
            quarantineOpRowId: claimant.id,
          );
        }
        // Nothing at head + 1 chains to the head: a lone refusing claimant ends
        // the scan exactly as it always did.
        if (winner == null) break;
        final releasing = winner;
        // Durable re-arm marker, committed as its **own** statement *before* the
        // replay unit below so a storage fault that rolls the release back cannot
        // take it with it. Only the winner is ever marked — a fork/mismatch
        // claimant never reaches here (`winner` is set only for a non-refusing
        // verdict) — so `release_started_at` names an interrupted replay and
        // nothing else, which is what keeps the re-arm off a standing fork.
        await _markReleaseStarted(releasing.id);
        // Release + re-entry as one **top-level** unit (#620). A storage fault
        // rolls the `_markReleased` back and keeps the row a claimant, while the
        // pre-committed marker above survives to re-arm the next pull. Released
        // *before* re-entry so the loop's unreleased set strictly shrinks and it
        // still terminates; the winner's own #618 `_receive` transaction nests
        // under this one as a savepoint. Losers keep no `released_at` and are
        // re-alarmed at most once per iteration — if the winner's re-receive
        // refuses for a *non-storage* reason it returns normally, the head does
        // not advance, and the next iteration sees them again.
        try {
          affected.addAll(await _db.transaction(() async {
            await _markReleased(releasing.id);
            return _receive(
              PulledOp(seq: releasing.seq!, envelope: releasing.envelope),
            );
          }));
        } on SqliteException {
          // The transaction rolled `_markReleased` back, so the row is a claimant
          // again and the pre-committed `release_started_at` re-arms the next
          // pull. A storage fault is about our DB, not the envelope — retrying
          // the same write in a spin would not help — so it unwinds the whole
          // scan rather than continuing the loop.
          _chainSuccessorReplayRetryRequired = true;
          rethrow;
        }
        releasedAny = true;
      }
      // A full scan completed with no storage fault (a fault rethrows above and
      // never reaches here). Every marker still standing on an unreleased row now
      // belongs to a claimant this pass did not release — a standing fork/gap,
      // not an in-flight replay — so clear it. This is what keeps the re-arm
      // predicate off a winner that has since become a fork, so repeated pulls
      // neither re-run the scan nor re-raise its alarm (AC-4).
      await _clearReleaseStarted(authorMemberId);
      if (releasedAny) {
        if (!attestationBridged) {
          await _raiseAlarm(
            IntegrityAlarmKind.authorStreamReordered,
            authorMemberId: authorMemberId,
            detail: 'quarantined successors became chain-valid as their '
                'predecessors arrived',
          );
        }
        // The standing-gap rule: the gap alarm is only reclassified away once
        // nothing is still missing. While one refused row stands unreleased, the
        // reorder is recorded alongside the gap rather than instead of it.
        //
        // **And only once nothing is still waiting to be put on screen.** The
        // User may have answered a gap with *take upstream* and the projection
        // that puts the change on their screen may have failed. The chain
        // release does not finish that work — it re-admits the row and writes
        // the change into the log, and neither puts it on the screen — so the
        // accusation stays standing until the recovery has projected it. Closing
        // it here would leave the change reduced but unseen, with nothing left
        // to ask about.
        if (!await _hasUnreleasedGap(authorMemberId) &&
            !await _hasUnprojectedTakeUpstream(authorMemberId)) {
          await _resolveAlarm(IntegrityAlarmKind.authorChainGap, authorMemberId);
        }
      }
    } finally {
      _releasingChainOfAuthors.remove(authorMemberId);
    }
    return affected;
  }

  /// Every row that could now be chain-valid at one position — still a point
  /// lookup by `(author, head + 1)`, never a table walk.
  ///
  /// It returns a list because several envelopes can claim one `author_seq`: a
  /// forged alternate and the genuine op both quarantine as gap rows there, and
  /// which of them arrived first is the server's choice rather than evidence.
  Future<List<QuarantineRow>> _quarantinedGapClaimantsAt(
    String authorMemberId,
    int authorSeq,
  ) =>
      (_db.select(_db.quarantinedOps)
            ..where((row) =>
                row.workspaceId.equals(workspaceId) &
                row.authorMemberId.equals(authorMemberId) &
                row.authorSeq.equals(authorSeq) &
                row.releasedAt.isNull() &
                row.reason.equals(SyncRejectionReason.authorChainGap.code))
            ..orderBy([(row) => OrderingTerm(expression: row.id)]))
          .get();

  Future<bool> _hasUnreleasedGap(String authorMemberId) async {
    final rows = await (_db.select(_db.quarantinedOps)
          ..where((row) =>
              row.workspaceId.equals(workspaceId) &
              row.authorMemberId.equals(authorMemberId) &
              row.releasedAt.isNull() &
              row.reason.equals(SyncRejectionReason.authorChainGap.code))
          ..limit(1))
        .get();
    return rows.isNotEmpty;
  }

  /// The author has a take upstream that has not reached the domain store yet.
  ///
  /// The decision was recorded and the change was applied to the reduced
  /// state, but the projection that puts it on the User's screen has not
  /// succeeded. That is work still to be done, and it stays work to be done
  /// until the projection succeeds — a chain release re-admits the row and
  /// writes the change into the log, and neither of those puts it on screen.
  Future<bool> _hasUnprojectedTakeUpstream(String authorMemberId) async {
    final rows = await (_db.select(_db.quarantinedOps)
          ..where((row) =>
              row.workspaceId.equals(workspaceId) &
              row.authorMemberId.equals(authorMemberId) &
              row.resolution.equals(AlarmResolution.tookUpstream.code) &
              row.resolutionProjectedAt.isNull())
          ..limit(1))
        .get();
    return rows.isNotEmpty;
  }

  Future<void> _markReleased(int quarantineRowId) async {
    await (_db.update(_db.quarantinedOps)..where((row) => row.id.equals(quarantineRowId)))
        .write(QuarantinedOpsCompanion(releasedAt: Value(_now())));
  }

  /// Stamp the interrupted-chain-replay re-arm marker on one winner (#620).
  ///
  /// Written as its own committed statement *before* the release transaction, so
  /// a storage fault that rolls the release back leaves this timestamp standing —
  /// the signal that a replay began and never finished.
  Future<void> _markReleaseStarted(int quarantineRowId) async {
    await (_db.update(_db.quarantinedOps)..where((row) => row.id.equals(quarantineRowId)))
        .write(QuarantinedOpsCompanion(releaseStartedAt: Value(_now())));
  }

  /// Clear the re-arm marker for every one of [authorMemberId]'s rows that still
  /// carries it, once a full scan has completed without a storage fault.
  ///
  /// After a clean pass, any marked row is either released (its `released_at` is
  /// set) or a claimant the scan did not release — a standing fork/gap, no longer
  /// an interrupted replay. Clearing the marker keeps [_hasInterruptedChainReplay]
  /// from matching it, so the standing-fork steady state never re-runs the scan.
  Future<void> _clearReleaseStarted(String authorMemberId) async {
    await (_db.update(_db.quarantinedOps)
          ..where((row) =>
              row.workspaceId.equals(workspaceId) &
              row.authorMemberId.equals(authorMemberId) &
              row.releaseStartedAt.isNotNull()))
        .write(const QuarantinedOpsCompanion(releaseStartedAt: Value(null)));
  }

  /// Whether any row is mid-interrupted-replay — the restart-safe half of the
  /// chain-successor re-arm, counterpart to [_hasOpsAwaitingEpoch].
  ///
  /// A row released to a claimant by a rolled-back replay reads
  /// `released_at IS NULL AND release_started_at IS NOT NULL`. A standing fork
  /// never carries `release_started_at`, so this stays false for it and the
  /// re-arm reintroduces none of the churn AC-4 forbids. The `LIMIT 1` gates a
  /// pull that interrupted nothing out of the scan entirely.
  Future<bool> _hasInterruptedChainReplay() async {
    final rows = await (_db.select(_db.quarantinedOps)
          ..where((row) =>
              row.workspaceId.equals(workspaceId) &
              row.releasedAt.isNull() &
              row.releaseStartedAt.isNotNull())
          ..limit(1))
        .get();
    return rows.isNotEmpty;
  }

  /// The authors with an interrupted chain-successor replay to retry — the scan
  /// runs per author, so the re-arm has to know whose chains to re-drive.
  Future<List<String>> _authorsWithInterruptedChainReplay() async {
    final rows = await (_db.select(_db.quarantinedOps)
          ..where((row) =>
              row.workspaceId.equals(workspaceId) &
              row.releasedAt.isNull() &
              row.releaseStartedAt.isNotNull() &
              row.authorMemberId.isNotNull()))
        .get();
    return {for (final row in rows) row.authorMemberId!}.toList();
  }

  /// Per-type control verification, in D7's normative order, before anything is
  /// applied.
  ///
  /// Four served types, one dispatch. Two of them — `workspace_genesis` and
  /// `member_register` — carry their author's own registration, which is why the
  /// envelope-signature check *defers* into here: the directory by definition has
  /// no entry for an author that is registering itself. The other two are authored
  /// by members the directory already knows, so their envelopes are verified
  /// against the ordinary chain-gated key.
  ///
  /// Step "the certificate's key must actually have signed this envelope" is the
  /// load-bearing one for the registering pair. A genuine certificate is public
  /// the moment it is in the log; without it, anyone holding a copy could wrap it
  /// around self-signed envelopes and manufacture forks in the victim's chain.
  ///
  /// **Produces no side effects.** Nothing here writes, so the caller can log the
  /// envelope between this and [_applyControlOp] — the op_log row must exist before
  /// any authority effect does, and it must not exist for bytes that never verified.
  /// Whatever the type teaches this device is carried out in the returned
  /// [_VerifiedControlOp] rather than applied here.
  Future<_VerifiedControlOp> _verifyControlOp(
    PulledOp pulled,
    Uint8List body,
    OpHeader header,
  ) async {
    final payloadBytes = parseBody(body);
    final payload = ControlPayload.decode(payloadBytes);
    payload.requireServedType();
    payload.requireChainLinkShape();

    final rootPk = await pinnedRootPk();
    if (rootPk == null) {
      throw const SyncRejection(
        SyncRejectionReason.badRootSignature,
        'no Root is pinned on this device, so no control op can be verified',
      );
    }

    // Verification first, and it produces no side effects: whatever the type
    // teaches this device is held back until the chain check below has run, so a
    // refused op never leaves a key in the directory behind it.
    RegistrationCertificate? learned;
    switch (payload.controlType) {
      case controlTypeWorkspaceGenesis:
        await verifyGenesisCertificate(payload.certBytes, payload.rootSig, rootPk);
        final genesis = payload.genesisCertificate();
        // Workspace before Root, which is the order the ops route asks them in.
        // With two distinct codes the sub-order decides which one a genesis that
        // disagrees on *both* fields earns, so the two verifiers have to agree
        // about the order and not merely about each check in isolation — pinned
        // by `control_certificate_workspace_and_root_pk_mismatch`.
        if (genesis.workspaceId != workspaceId) {
          throw SyncRejection(
            SyncRejectionReason.certWorkspaceMismatch,
            'genesis names workspace ${genesis.workspaceId}, pulled from $workspaceId',
          );
        }
        if (!sameBytes(genesis.rootPk, rootPk)) {
          // The Root inside the signed genesis must be the Root this device
          // pinned: that cross-check is why it is in there at all. The Root
          // signature verified over these very bytes, so nothing is wrong with
          // the signature — what disagrees is the Root the document names.
          throw const SyncRejection(
            SyncRejectionReason.certRootPkMismatch,
            'the genesis names a different Root than this device pinned',
          );
        }
        learned = genesis.asRegistration();
        await _bindRegistrationToEnvelope(learned, pulled, header);

      case controlTypeMemberRegister:
        await verifyRegistrationCertificate(payload.certBytes, payload.rootSig, rootPk);
        final certificate = payload.certificate();
        if (certificate.workspaceId != workspaceId) {
          throw SyncRejection(
            SyncRejectionReason.certWorkspaceMismatch,
            'certificate names workspace ${certificate.workspaceId}, pulled from '
            '$workspaceId',
          );
        }
        await _bindRegistrationToEnvelope(certificate, pulled, header);
        learned = certificate;

      case controlTypeGrant:
        await _receiveGrant(pulled, payload, header, rootPk);

      case controlTypeRevoke:
        await _receiveRevoke(pulled, payload, header, rootPk);

      case controlTypeRotate:
        await _receiveRotate(pulled, payload, header);

      default:
        // Unreachable: `requireServedType` already refused it.
        throw SyncRejection(
          SyncRejectionReason.unsupportedControlType,
          'control type "${payload.controlType}" is not served',
        );
    }

    return _VerifiedControlOp(
      payload: payload,
      payloadBytes: payloadBytes,
      learned: learned,
    );
  }

  /// Position a verified control op and apply what it stands for.
  ///
  /// Split from [_verifyControlOp] so the `op_log` row lands between the two: the
  /// authority effects below — the directory entry, the epoch floor, the
  /// `applied_control_log` row — must never exist without a row behind them, or a
  /// server spending one transport `seq` on two chain-valid control ops lands the
  /// second one's authority with nothing for a later content op to chain to.
  /// Returns the [RegistrationCertificate] this op teaches the directory, or null.
  /// The caller applies it to [directory] **after** the receive transaction
  /// commits (see [_receive]'s control branch), so a rolled-back durable record
  /// never leaves a live chained key behind it.
  Future<RegistrationCertificate?> _applyControlOp(
    PulledOp pulled,
    OpHeader header,
    _VerifiedControlOp verified,
  ) async {
    final payload = verified.payload;
    // Position and chain, **last** — the same place #548's six-step order put it.
    // Authority is judged on the bytes, which is a question about the op alone; the
    // chain is a question about this receiver's own state, and asking it first
    // would mask a forged certificate behind a chain complaint. A fork here is
    // *resolved* rather than refused (F14e), and only the winning branch applies.
    final applied = await _appliedControlLog();
    if (await _resolveControlPosition(pulled, payload, header, applied) ==
        _ControlPosition.quarantineThis) {
      throw SyncRejection(
        SyncRejectionReason.controlChainFork,
        _forkRefusalDetail(pulled.seq, payload.prevControlHash),
      );
    }

    // Verified *and* positioned: the op may now teach this device a chained key,
    // but the caller remembers it post-commit (see [_receive]) rather than here,
    // so no in-memory key outlives a durable record that rolled back.
    final learned = verified.learned;
    if (payload.controlType == controlTypeWorkspaceGenesis) {
      // Genesis fixes the epoch floor at 0. Recorded rather than assumed, so a
      // Workspace's floor exists from the moment the Workspace does.
      await raiseEpochFloor(0);
    }
    if (payload.controlType == controlTypeRotate) {
      // **The floor's only production raiser**, and the whole point of applying a
      // rotate. From here this device refuses to *author* below the new epoch, so a
      // rotation cannot be undone by the next offline write — and a suppressed
      // rotation is detectable as the author-chain gap in the rotating owner's
      // stream plus a floor that stopped moving.
      //
      // The statement's `from_epoch` is deliberately **not** checked against the
      // local floor. `raiseEpochFloor` clamps, so an older rotate re-served is the
      // no-op it should be, and a *skipped* rotation is impossible for a receiver to
      // reach: `to_epoch == from_epoch + 1` is a decode invariant and the control
      // chain fixes the order the steps apply in. A second check here would be a
      // second place for the two to disagree.
      final priorFloor = await epochFloor();
      final raisedFloor = await raiseEpochFloor(payload.rotateStatement().toEpoch);
      _epochKeyRefreshRequired = true;
      // Arm the future-epoch release only when the floor genuinely rose.
      // `raiseEpochFloor` returns the clamped maximum, so an older rotate re-served
      // returns the unchanged floor and must not arm a scan with nothing to release
      // — that would be the re-examination churn the flag exists to prevent.
      if (raisedFloor > priorFloor) _epochFloorRaised = true;
    }
    await _appendAppliedControlOp(pulled, payload, header, verified.payloadBytes);
    return learned;
  }

  /// The detail of a control op that lost the fork tie-break.
  ///
  /// Shared with [_replaceRefusedBreak], so a refusal the scan recovers says
  /// the same thing as the one the receive filed.
  String _forkRefusalDetail(int seq, Uint8List prevControlHash) =>
      'control op at seq $seq lost the fork tie-break for '
      'prev_control_hash ${_hex(prevControlHash)}';

  /// The registering pair's binding steps: the certificate must be *about* this
  /// author, and its own key must have signed this envelope.
  Future<void> _bindRegistrationToEnvelope(
    RegistrationCertificate certificate,
    PulledOp pulled,
    OpHeader header,
  ) async {
    if (certificate.memberId != header.authorMemberId) {
      throw SyncRejection(
        SyncRejectionReason.certMemberMismatch,
        'certificate names ${certificate.memberId}, envelope author is '
        '${header.authorMemberId}',
      );
    }
    await verifyEnvelope(pulled.envelope, certificate.signPk);
    if (!sameBytes(certificate.signKeyId, header.authorKeyId)) {
      throw const SyncRejection(
        SyncRejectionReason.certKeyMismatch,
        'certificate key id is not the one the header names',
      );
    }
    if (header.authorSeq != 1) {
      // D1's generalisation of #548's rule: an author's first op must be the
      // control op that registers it.
      throw SyncRejection(
        SyncRejectionReason.controlChainBreak,
        'a registering control op must be its author\'s first op, not seq '
        '${header.authorSeq}',
      );
    }
  }

  /// Verify one Grant: the authority signed it, and the grantee is resolvable.
  Future<void> _receiveGrant(
    PulledOp pulled,
    ControlPayload payload,
    OpHeader header,
    Uint8List rootPk,
  ) async {
    // The envelope first: a Grant's author is an already-registered member, so
    // the chain-gated directory holds its key and there is nothing to defer.
    await verifyEnvelope(
      pulled.envelope,
      directory.publicKeyFor(header.authorMemberId, header.authorKeyId),
    );
    final authorityPk = await _authorityPublicKey(payload.authority, header, pulled.seq, rootPk);
    await verifyGrantCertificate(payload.certBytes, payload.signature, authorityPk);
    // Decoded *after* the signature check: parsing first would be reading an
    // unauthenticated document. `owner_grant_requires_root` fires in here.
    final grant = payload.grantCertificate();
    if (grant.workspaceId != workspaceId) {
      throw SyncRejection(
        SyncRejectionReason.certWorkspaceMismatch,
        'grant names workspace ${grant.workspaceId}, pulled from $workspaceId',
      );
    }
    if (grant.granter != payload.authority) {
      // The signed certificate names its own granter; the payload's field only
      // says which key to check it against. The certificate verified under that
      // key, so this is a forgery attempt rather than a broken signature —
      // `bad_grant_signature` would accuse a signature nothing is wrong with.
      throw const SyncRejection(
        SyncRejectionReason.certGranterMismatch,
        'the certificate and the payload disagree about the granter',
      );
    }
    if (!directory.isChained(grant.memberId)) {
      // Fail closed on an unmaterialised grantee: never a dangling forward
      // reference. The bar is the chain-gated directory, which is stricter than
      // anything the server could assert.
      throw SyncRejection(
        SyncRejectionReason.unknownGrantee,
        'no verified registration for grantee ${grant.memberId}',
      );
    }
    if (isPreferencesWorkspace && directory.kindOf(grant.memberId) != memberKindDevice) {
      // The client-side half of "every Device, no Service ever". Refused to
      // *apply*, not merely refused to author: a served Service grant into the
      // preferences Workspace must be inert on every device.
      throw SyncRejection(
        SyncRejectionReason.serviceGrantForbidden,
        'the user_preferences Workspace grants no Service; ${grant.memberId} is '
        'a ${directory.kindOf(grant.memberId)}',
      );
    }
  }

  /// Verify one `rotate`: the envelope's own signature, and a live owner Grant.
  ///
  /// **The one served type with no second signature to check**, and that is a
  /// consequence rather than a gap. Every other type's authority is somebody other
  /// than the author — Root, or a granting Member — so its certificate travels
  /// separately signed. A rotate's authority is the author's *own* live `owner`
  /// Grant, which is the `(role, op_class)` rule already applied everywhere, and the
  /// fields it asserts **are** the body the envelope signature covers. A rotate
  /// therefore cannot land on a Root signature alone, unlike every sibling.
  Future<void> _receiveRotate(
    PulledOp pulled,
    ControlPayload payload,
    OpHeader header,
  ) async {
    await verifyEnvelope(
      pulled.envelope,
      directory.publicKeyFor(header.authorMemberId, header.authorKeyId),
    );
    // Decoded after the signature check, as the grant path decodes after its own:
    // parsing first would be reading an unauthenticated document.
    final rotate = payload.rotateStatement();
    if (rotate.workspaceId != workspaceId) {
      throw SyncRejection(
        SyncRejectionReason.certWorkspaceMismatch,
        'rotate names workspace ${rotate.workspaceId}, pulled from $workspaceId',
      );
    }
    if (!(await grantsView()).wasOwnerAt(header.authorMemberId, pulled.seq)) {
      // Positional, at the op's own seq, like every other authorization verdict: a
      // rotate authored while its author still held owner stays valid when a later
      // revocation arrives.
      throw SyncRejection(
        SyncRejectionReason.noLiveGrant,
        'member ${header.authorMemberId} held no live owner Grant at seq '
        '${pulled.seq}, so it cannot rotate this Workspace\'s key',
      );
    }
  }

  /// Verify one Revoke, including the revoke half of the owner ceiling.
  Future<void> _receiveRevoke(
    PulledOp pulled,
    ControlPayload payload,
    OpHeader header,
    Uint8List rootPk,
  ) async {
    await verifyEnvelope(
      pulled.envelope,
      directory.publicKeyFor(header.authorMemberId, header.authorKeyId),
    );
    final authorityPk = await _authorityPublicKey(payload.authority, header, pulled.seq, rootPk);
    await verifyRevokeCertificate(payload.certBytes, payload.signature, authorityPk);
    final revoke = payload.revokeCertificate();
    if (revoke.workspaceId != workspaceId) {
      throw SyncRejection(
        SyncRejectionReason.certWorkspaceMismatch,
        'revoke names workspace ${revoke.workspaceId}, pulled from $workspaceId',
      );
    }
    if (revoke.revoker != payload.authority) {
      // The same reading as the Grant half, and under the *same* code: the
      // server does not split granter from revoker at 422, so neither may a
      // client.
      throw const SyncRejection(
        SyncRejectionReason.certGranterMismatch,
        'the certificate and the payload disagree about the revoker',
      );
    }
    final target = (await grantsView()).grants[revoke.grantId];
    if (target == null) {
      throw SyncRejection(
        SyncRejectionReason.unknownGrant,
        'no applied Grant ${revoke.grantId} for this Revoke to unmake',
      );
    }
    if (target.role == roleOwner && payload.authority != granterRoot) {
      // The revoke half of the ceiling, and the one half that *needs* state: the
      // frozen revoke certificate names a grant id, not a role, so only a
      // receiver holding the Grant can tell an owner revocation from any other.
      throw const SyncRejection(
        SyncRejectionReason.ownerRevokeRequiresRoot,
        'an owner Grant may only be revoked by Root',
      );
    }
  }

  /// Whose key must have signed a grant or revoke certificate.
  ///
  /// Root, or the authoring Member itself — **authority does not travel by
  /// courier**. A member-signed control op additionally needs a live *owner*
  /// Grant at this op's own seq, which is the matrix's `op_class = 2` row.
  Future<Uint8List> _authorityPublicKey(
    String authority,
    OpHeader header,
    int seq,
    Uint8List rootPk,
  ) async {
    if (authority == granterRoot) return rootPk;
    if (authority != header.authorMemberId) {
      // The same code the server's `_authority_public_key` returns, and for the
      // same reason: nothing has been verified yet, so this is no claim about a
      // signature — the payload nominates an authority the envelope's author
      // does not hold.
      throw SyncRejection(
        SyncRejectionReason.certGranterMismatch,
        'a member-signed control op must be authored by the member whose '
        'authority it claims',
      );
    }
    if (!(await grantsView()).wasOwnerAt(authority, seq)) {
      throw SyncRejection(
        SyncRejectionReason.noLiveGrant,
        'member $authority held no live owner Grant at seq $seq',
      );
    }
    return directory.publicKeyFor(header.authorMemberId, header.authorKeyId);
  }
  // --- The applied control log, and the grants view derived from it -----------

  Future<List<AppliedControlRow>> _appliedControlLog({bool includeQuarantined = false}) =>
      (_db.select(_db.appliedControlLog)
            ..where((row) => includeQuarantined
                ? row.workspaceId.equals(workspaceId)
                : row.workspaceId.equals(workspaceId) & row.quarantinedAt.isNull())
            ..orderBy([(row) => OrderingTerm(expression: row.seq)]))
          .get();

  /// The head of the applied control log, or [_noAppliedControlHead] for a
  /// Workspace that has applied no control op yet.
  ///
  /// Read from the log rather than from [appliedControlHead], because the two can
  /// part company: a fork resolution quarantines a branch, and the log's head is
  /// then a row the chain state has not caught up with yet.
  Future<_AppliedControlHead> _appliedControlHeadState() async {
    final applied = await _appliedControlLog();
    if (applied.isEmpty) return _noAppliedControlHead;
    final head = applied.last;
    return _AppliedControlHead(seq: head.seq, payloadHash: head.payloadHash);
  }

  /// Whether two applied control heads are the same head.
  ///
  /// Both halves are compared: the scan's gate asks whether the head *moved*,
  /// and the head's transport `seq` moves the boundary a refused op has to sit
  /// above even when the payload hash does not change.
  bool _sameAppliedControlHead(_AppliedControlHead a, _AppliedControlHead b) =>
      a.seq == b.seq && sameBytes(a.payloadHash, b.payloadHash);

  /// Whether the chained-member directory has been refilled from the applied
  /// control log yet.
  bool _chainedMembersRestored = false;

  /// Refill [directory] from the registrations this device already verified and
  /// applied.
  ///
  /// The directory of other devices' keys lives only in memory, and the only
  /// thing that ever fills it is a *pulled* registration. The pull cursor is
  /// stored and outlives the process, so after a relaunch the server never
  /// serves those registrations again: the directory comes back empty and every
  /// change from another device is refused as `member_not_chained_to_root`.
  ///
  /// The registrations are not stored a second time — they are already in the
  /// applied control log, byte for byte, and this reads them from there. A row
  /// exists in that table only after the full verification in `_verifyControlOp`
  /// and the chain check in `_applyControlOp`, so restoring one restores a fact
  /// this device already established rather than trusting something new: a key
  /// Root never vouched for has no row and is still refused.
  ///
  /// The Root signature is not re-checked here. The rows were verified before
  /// they were written, the grants view already trusts them unverified, and
  /// anyone able to rewrite this database could rewrite the pinned Root too, so a
  /// second check would protect nothing.
  ///
  /// Rows on a losing control-fork branch are left out, which is the same row
  /// set the grants view reads. A running session keeps such a key until it
  /// exits, so for that one case a restarted device reports
  /// `member_not_chained_to_root` where a running one reports `no_live_grant`.
  /// Both refuse the change; the restart is the stricter of the two.
  Future<void> restoreChainedMembersFromAppliedControlLog() async {
    if (_chainedMembersRestored) return;
    for (final row in await _appliedControlLog()) {
      switch (row.controlType) {
        case controlTypeWorkspaceGenesis:
          directory.rememberChained(
            ControlPayload.decode(row.payloadBytes)
                .genesisCertificate()
                .asRegistration(),
          );
        case controlTypeMemberRegister:
          directory.rememberChained(
            ControlPayload.decode(row.payloadBytes).certificate(),
          );
      }
    }
    _chainedMembersRestored = true;
  }

  /// The grants view, derived from the applied control log.
  ///
  /// Nothing about the view is *stored*: [_grantsViewCache] lives only in memory
  /// and only until the applied control log next changes, which is the one thing
  /// that can move a verdict. It exists because the receive path asks for the view
  /// once per **content** op, and recomputing it means re-reading every control row
  /// and base64+JSON-decoding every payload again — a bootstrap pull of N content
  /// ops over M control ops costs N×M decodes without it, and O(M) with it.
  ///
  /// Per the repo naming rule the retained copy says so in its name. Every writer
  /// of `applied_control_log` — [_appendAppliedControlOp] and
  /// [_quarantineControlBranch] — drops it, so there is no window in which a stale
  /// view can be read.
  GrantsView? _grantsViewCache;

  void _invalidateGrantsViewCache() => _grantsViewCache = null;

  Future<GrantsView> grantsView() async {
    final cached = _grantsViewCache;
    if (cached != null) return cached;
    return _grantsViewCache = await _deriveGrantsView();
  }

  Future<GrantsView> _deriveGrantsView() async {
    final rows = await _appliedControlLog();
    final grants = <String, DerivedGrant>{};
    for (final row in rows) {
      final payload = ControlPayload.decode(row.payloadBytes);
      switch (row.controlType) {
        case controlTypeGrant:
          final grant = payload.grantCertificate();
          grants[grant.grantId] = DerivedGrant(
            grantId: grant.grantId,
            memberId: grant.memberId,
            role: grant.role,
            granter: grant.granter,
            grantedSeq: row.seq,
          );
        case controlTypeRevoke:
          final revoke = payload.revokeCertificate();
          final existing = grants[revoke.grantId];
          // A Revoke for a Grant this device never applied is dropped rather than
          // remembered: the verification stage already refused that case, so
          // reaching here means the Grant was quarantined on a losing fork branch.
          if (existing == null) continue;
          // First revocation wins. The verdict is positional
          // (`grantedSeq < seq < revokedBySeq`), so letting a later Revoke move
          // `revokedBySeq` forward would *widen* the window an already-revoked
          // Grant covers — the boundary is immutable once stamped.
          if (existing.revokedBySeq != null) continue;
          grants[revoke.grantId] = DerivedGrant(
            grantId: existing.grantId,
            memberId: existing.memberId,
            role: existing.role,
            granter: existing.granter,
            grantedSeq: existing.grantedSeq,
            revokedBySeq: row.seq,
          );
      }
    }
    return GrantsView(grants);
  }

  /// Every applied Grant, live or not — the surface #553's device list reads.
  Future<List<DerivedGrant>> grants() async =>
      (await grantsView()).grants.values.toList()
        ..sort((a, b) => a.grantedSeq.compareTo(b.grantedSeq));

  /// Live Grants with no current-epoch KeyWrap.
  ///
  /// **Decidable for this device's own Grants and no others.** A KeyWrap is sealed to
  /// one Member and `GET /w/{w}/keywraps/me` is the only wrap route there is, so a
  /// device cannot observe whether a *peer* was wrapped to — and reporting every peer
  /// as orphaned for want of evidence would make the surface useless. Peers are
  /// therefore passed as wrapped: not an optimistic assumption but the only honest
  /// one, and the wrap set they belong to is already committed to by the `rotate`
  /// op's digest, which the server cannot curate.
  ///
  /// An orphaned own Grant is what drives the bounded KeyWrap re-fetch (F14b): it
  /// says "this device holds a live Grant and cannot read the current epoch", which
  /// is the freshness window after a rotation, and it clears itself when the wrap
  /// arrives.
  Future<List<DerivedGrant>> orphanedGrants() async {
    final currentEpoch = await epochFloor();
    final view = await grantsView();
    final holdsCurrentKey =
        await workspaceKeys.keyFor(workspaceId, currentEpoch) != null;
    return view
        .orphanedGrants(
          currentEpoch: currentEpoch,
          keyWrappedGrantIds: {
            for (final grant in view.grants.values)
              if (holdsCurrentKey || grant.memberId != identity.memberId)
                grant.grantId,
          },
        )
        .toList();
  }

  Future<void> _appendAppliedControlOp(
    PulledOp pulled,
    ControlPayload payload,
    OpHeader header,
    Uint8List payloadBytes,
  ) async {
    final hlc = _certificateHlc(payload);
    await _db.into(_db.appliedControlLog).insertOnConflictUpdate(
          AppliedControlLogCompanion.insert(
            workspaceId: workspaceId,
            seq: pulled.seq,
            controlType: payload.controlType,
            payloadBytes: payloadBytes,
            payloadHash: controlPayloadHash(payloadBytes),
            prevControlHash: payload.prevControlHash,
            authorMemberId: header.authorMemberId,
            certWallMs: hlc.wallMs,
            certCounter: hlc.counter,
            appliedAt: _now(),
          ),
        );
    _invalidateGrantsViewCache();
    // The head is derived from the log rather than incremented, so a fork
    // resolution that quarantines a branch cannot leave the counter lying — and
    // that derivation is the *only* writer of `controlChainState`. An upsert here
    // would be superseded by it a line later, and would meanwhile publish the
    // pre-insert `appliedCount`, leaving the counter short if the process died in
    // between.
    await _refreshControlChainHead();
  }

  /// The certificate's own clock — the fork tie-break's first key.
  ///
  /// Deliberately not the op-level HLC: a forking author could otherwise move the
  /// tie by re-signing an envelope around the same certificate.
  Hlc _certificateHlc(ControlPayload payload) => switch (payload.controlType) {
        controlTypeWorkspaceGenesis => payload.genesisCertificate().createdAtHlc,
        controlTypeMemberRegister => payload.certificate().registeredAtHlc,
        controlTypeGrant => payload.grantCertificate().grantedAtHlc,
        controlTypeRevoke => payload.revokeCertificate().revokedAtHlc,
        // A rotate carries no certificate, so its own `rotated_at_hlc` is the clock
        // the tie-break reads — the same field, one document up.
        controlTypeRotate => payload.rotateStatement().rotatedAtHlc,
        _ => throw SyncRejection(
            SyncRejectionReason.unsupportedControlType,
            'control type "${payload.controlType}" carries no certificate clock',
          ),
      };

  /// Recompute `controlChainState` from the applied log.
  Future<void> _refreshControlChainHead() async {
    final rows = await _appliedControlLog();
    await _db.into(_db.controlChainState).insertOnConflictUpdate(
          ControlChainStateCompanion.insert(
            workspaceId: workspaceId,
            lastControlPayloadHash:
                rows.isEmpty ? zeroPrevControlHash : rows.last.payloadHash,
            appliedCount: rows.length,
          ),
        );
  }

  Future<ControlChainRow?> _controlChain() => (_db.select(_db.controlChainState)
        ..where((row) => row.workspaceId.equals(workspaceId)))
      .getSingleOrNull();

  /// The chain link a control op this device authors next must name.
  Future<Uint8List> appliedControlHead() async =>
      (await _controlChain())?.lastControlPayloadHash ?? zeroPrevControlHash;

  /// Whether this Workspace's applied control log already holds **this device's**
  /// own registration.
  ///
  /// A registration is a `workspace_genesis` — the device founded the Workspace —
  /// or a `member_register` — it joined one. The *author* is what makes it this
  /// device's: the control log is shared by every Member of the Workspace, and
  /// a peer's registration says nothing about whether this device may claim one.
  ///
  /// Read from the applied log and not from the member directory, because the
  /// directory is shared by the Workspaces of one User: it would report this
  /// device as registered in a Workspace it has never claimed.
  Future<bool> ownRegistrationApplied() async {
    final memberId = identity.memberId;
    for (final row in await _appliedControlLog()) {
      if (row.authorMemberId != memberId) continue;
      if (row.controlType == controlTypeMemberRegister ||
          row.controlType == controlTypeWorkspaceGenesis) {
        return true;
      }
    }
    return false;
  }

  // --- Control fork resolution (F14e) ----------------------------------------

  /// Whether an arriving control op wins its position, and what to do if it does.
  ///
  /// Two applied-or-arriving control ops naming the same predecessor are a fork.
  /// The winner is **earliest certificate HLC, then lowest author member id** —
  /// deterministic and order-independent, so every device reaches the same answer
  /// whichever order it saw them in. Mutual owner revocation is exactly this case
  /// and needs no extra machinery.
  Future<_ControlPosition> _resolveControlPosition(
    PulledOp pulled,
    ControlPayload payload,
    OpHeader header,
    List<AppliedControlRow> applied,
  ) async {
    final expected = applied.isEmpty ? zeroPrevControlHash : applied.last.payloadHash;
    if (sameBytes(payload.prevControlHash, expected)) {
      return _ControlPosition.accept;
    }

    final rival = applied
        .where((row) => sameBytes(row.prevControlHash, payload.prevControlHash))
        .firstOrNull;
    if (rival == null) {
      // Not a fork — a skip or a restart. The chain names a predecessor this
      // device does not hold at the head, and nothing here claims that position.
      throw SyncRejection(
        SyncRejectionReason.controlChainBreak,
        'prev_control_hash does not name the last applied control op '
        '(${applied.length} applied)',
      );
    }

    final hlc = _certificateHlc(payload);
    if (_arrivalWinsTieBreak(
      arrivalWallMs: hlc.wallMs,
      arrivalCounter: hlc.counter,
      arrivalAuthorMemberId: header.authorMemberId,
      rival: rival,
    )) {
      // The already-applied branch loses. Quarantine it and everything chaining
      // through it, then re-reduce content under the corrected view.
      await _quarantineControlBranch(rival);
      return _ControlPosition.accept;
    }
    return _ControlPosition.quarantineThis;
  }

  /// Earliest cert HLC, then lowest author member id. Total and order-independent.
  bool _arrivalWinsTieBreak({
    required int arrivalWallMs,
    required int arrivalCounter,
    required String arrivalAuthorMemberId,
    required AppliedControlRow rival,
  }) {
    if (arrivalWallMs != rival.certWallMs) return arrivalWallMs < rival.certWallMs;
    if (arrivalCounter != rival.certCounter) return arrivalCounter < rival.certCounter;
    return arrivalAuthorMemberId.compareTo(rival.authorMemberId) < 0;
  }

  /// Quarantine a losing branch: the loser and every op chaining through it.
  ///
  /// Rows are marked rather than deleted — the log is evidence — and the branch is
  /// walked forward by payload hash so a long losing tail goes in one pass.
  Future<void> _quarantineControlBranch(AppliedControlRow loser) async {
    final applied = await _appliedControlLog();
    final doomed = <int>{loser.seq};
    var hashes = <Uint8List>[loser.payloadHash];
    while (hashes.isNotEmpty) {
      final next = <Uint8List>[];
      for (final row in applied) {
        if (doomed.contains(row.seq)) continue;
        if (hashes.any((hash) => sameBytes(row.prevControlHash, hash))) {
          doomed.add(row.seq);
          next.add(row.payloadHash);
        }
      }
      hashes = next;
    }
    final now = _now();
    for (final seq in doomed) {
      await (_db.update(_db.appliedControlLog)
            ..where((row) => row.workspaceId.equals(workspaceId) & row.seq.equals(seq)))
          .write(AppliedControlLogCompanion(quarantinedAt: Value(now)));
    }
    _invalidateGrantsViewCache();
    await _raiseAlarm(
      IntegrityAlarmKind.controlChainFork,
      detail: 'control fork resolved against ${doomed.length} applied op(s) '
          'starting at seq ${loser.seq}; the branch is quarantined and content '
          'was re-reduced under the winning grants view',
    );
    // A resolved control fork can change which *content* ops were authorized, so
    // convergence of the grants view alone is not convergence. Written inside
    // the transaction that stamped the quarantine, so the two commit together.
    await _requireRebuild();
  }

  // --- Suite dispatch and epoch keys -------------------------------------------

  /// Decode one content op's body under whichever suite its header names.
  ///
  /// The **whole** of the encryption read path, and it is a two-branch dispatch on
  /// one question — does this device hold `K_{w,key_epoch}`:
  ///
  /// * `aead_v1` with the key: open under the *literal received header bytes* as
  ///   AAD, then run [parseBody] on the plaintext. The padding rules therefore run
  ///   inside the AEAD rather than beside it, through the same function a
  ///   `plaintext_v1` body goes through.
  /// * `aead_v1` without the key: [SyncRejectionReason.missingEpochKey] — a
  ///   healable delivery gap, quarantined and re-tried once the wrap arrives.
  /// * `plaintext_v1` at an epoch we hold a key for:
  ///   [SyncRejectionReason.plaintextAtEncryptedEpoch] — the upgrade is one-way, and
  ///   this is the boundary that keeps it so.
  /// * `plaintext_v1` at an unkeyed epoch: the pre-turn-on path, unchanged for ever.
  Future<OpPayload> _decodeContentPayload(
    OpHeader header,
    Uint8List headerBytes,
    Uint8List body,
  ) async {
    // The epoch floor doubles as the applied-epoch **ceiling** on receive. The
    // floor is raised only by an applied genesis (to 0) or a verified `rotate`, so
    // `epochFloor()` is precisely the highest epoch this device's own control log
    // has established. Content above it is content from outside the rotation
    // boundary — an epoch no `rotate` this device applied created — so it is refused
    // on the server's word alone, the client mirror of the server's
    // `key_epoch_unknown` ceiling (#590). Checked **before** the `keyFor` lookup
    // because the verdict is about the epoch, not the key: `refreshEpochKeys` fetches
    // every epoch the server holds, so the wrap can arrive before its `rotate`. The
    // healer is the floor rising, not the key — see [_releaseOpsAwaitingEpoch].
    final floor = await epochFloor();
    if (header.keyEpoch > floor) {
      throw SyncRejection(
        SyncRejectionReason.keyEpochUnknown,
        'content at epoch ${header.keyEpoch} exceeds the applied epoch floor of '
        '$floor, which no rotate this device has applied has established',
      );
    }
    final workspaceKey = await workspaceKeys.keyFor(workspaceId, header.keyEpoch);
    if (header.suite == suiteAeadV1) {
      if (workspaceKey == null) {
        throw SyncRejection(
          SyncRejectionReason.missingEpochKey,
          'no key for epoch ${header.keyEpoch} of this Workspace on this device',
        );
      }
      return OpPayload.decode(parseBody(await openBody(
        headerBytes: headerBytes,
        body: body,
        workspaceKey: workspaceKey,
      )));
    }
    if (header.keyEpoch > 0 || workspaceKey != null) {
      // Judged on the **epoch**, not on whether this device happens to hold the
      // key. Above epoch 0 the epoch exists only because a `rotate` created it, so
      // a plaintext content op there is a downgrade whoever is reading — and
      // deciding it on local key availability would have devices awaiting their
      // wrap quietly reduce cleartext that every keyed peer refuses, which is the
      // two halves of one Workspace disagreeing about what applied.
      throw SyncRejection(
        SyncRejectionReason.plaintextAtEncryptedEpoch,
        'a content op at suite plaintext_v1 arrived at epoch ${header.keyEpoch}, '
        'which is a keyed epoch of this Workspace',
      );
    }
    return OpPayload.decode(parseBody(body));
  }

  /// Set when this pull learned that an epoch key it does not hold now exists.
  ///
  /// Acted on at the end of the pull rather than mid-page, for the stored rebuild marker's
  /// reason: a rotate and the first op at the new epoch usually arrive in one page,
  /// and re-fetching per op would spend a round-trip per op.
  bool _epochKeyRefreshRequired = false;

  /// Bumped every time the outbox is re-queued for a re-send ("keep ours").
  ///
  /// A flush remembers the generation it read its queue in. An acknowledgement
  /// that comes back after the queue was re-made belongs to the old queue: the
  /// server may have lost that very write in the rollback the re-send answers,
  /// so it must not mark the re-queued row sent.
  int _outboxQueueGeneration = 0;

  /// The directory's signing-key count at the last
  /// [_releaseOpsAwaitingMemberRegistration] scan.
  ///
  /// Null until that scan has run, so the first pull after any launch runs it:
  /// that is the heal for the rows a pre-#980 build left behind, because
  /// [SyncStack.assemble] has already restored the directory by then.
  int? _knownSigningKeyCountAtLastUnchainedScan;

  /// The applied control head at the last
  /// [_releaseOpsAwaitingControlPredecessor] scan.
  ///
  /// Null until that scan has run, so the first pull after any launch runs it and
  /// heals the rows an earlier build left behind. A Workspace with no applied
  /// control op has no head, and that is [_noAppliedControlHead] rather than
  /// null: the scan has run, and found nothing to work on.
  ///
  /// The head is remembered as a **sequence and a payload hash**, not as the hash
  /// alone: the scan's own gate asks whether a refused op sits above the head, and
  /// that is a question about the head's transport `seq`. A head whose hash did not
  /// change but whose `seq` did — the same control op read at another position —
  /// moves that boundary, so a scan gated on the hash alone would skip an op the
  /// new head now admits.
  _AppliedControlHead? _appliedControlHeadAtLastBreakScan;

  /// Set when this pull applied a `rotate` that actually **raised** the epoch floor.
  ///
  /// The trigger for [_releaseOpsAwaitingEpoch], the floor-keyed healer for
  /// [SyncRejectionReason.keyEpochUnknown]. Gating the release scan on this flag is
  /// what keeps a quarantined future-epoch op from being re-examined on every pull
  /// while its epoch is still unreached (no release churn): a pull that applied no
  /// floor-raising rotate leaves nothing to release, so the scan is skipped. Armed
  /// only when the floor genuinely rose — a re-served older rotate clamps to a no-op
  /// and must not arm it — and cleared once the scan has run.
  bool _epochFloorRaised = false;

  /// Set when a storage fault rolled a chain-successor replay back this session
  /// (#620), so the winner is a claimant again with its release unfinished.
  ///
  /// The same-session trigger for the re-arm at the end of [pull], mirroring
  /// [_epochFloorRaised]. The durable [_hasInterruptedChainReplay] marker is the
  /// restart-safe fallback across process death; this flag saves the read on the
  /// pull that raised it. Cleared once the re-arm scan has run.
  bool _chainSuccessorReplayRetryRequired = false;

  /// Set when a convergence pass threw, so the next pull runs them whatever it
  /// touched.
  ///
  /// The repair the flag re-arms is the only thing lost when it is — see
  /// [_reconcileProjected] for why that is a delay rather than a hole, and why the
  /// failure is swallowed at all.
  bool _reconcileRetryRequired = false;

  /// Fetch this Member's KeyWraps and learn every epoch key they carry.
  ///
  /// The ordinary delivery path, and it needs **no passphrase**: a wrap is sealed to
  /// this Device's own registered X25519 key, so the device that holds the seed can
  /// open it. The passphrase is only needed for the escrow route, which is the
  /// bootstrap case with no wrap yet (see `key_ceremony.dart`).
  ///
  /// Returns how many new epochs were learned. A wrap that does not open under our
  /// own key is an accusation rather than a crash: it is raised as an
  /// `aead_failure` alarm and the loop continues, because one substituted wrap must
  /// not stop the others from arriving.
  Future<int> refreshEpochKeys() async {
    final ownKexKeyId = deriveKeyId(identity.kexPk);
    var learned = 0;
    for (final record in await transport.fetchMyKeyWraps(workspaceId)) {
      // Neither of these is reachable through the real route — it serves
      // `jwt.member == row.member` only — so they are the fail-closed answer to a
      // server that serves something else, not a filter the protocol needs.
      if (record.memberId != identity.memberId) continue;
      if (!sameBytes(record.kexKeyId, ownKexKeyId)) continue;
      if (await workspaceKeys.keyFor(workspaceId, record.epoch) != null) continue;
      try {
        final epochKey = await unwrapEpochKeyForMember(
          wrap: record.wrap,
          kexKeyPair: identity.kexKeyPair,
          workspaceId: workspaceId,
          epoch: record.epoch,
          memberId: identity.memberId,
          kexKeyId: ownKexKeyId,
        );
        // A rebuild skips rows it cannot decode, and those rows are in `op_log`
        // rather than the quarantine, so the release scan never reaches them. A
        // newly arrived epoch key is the one event that can change that verdict,
        // so it owes a replay. Gated on *learning* rather than on the skip,
        // because an unconditional re-arm would replay the whole log on every
        // pull for as long as a key stayed missing. Stored **before** the key
        // is: a kill in between costs one extra, idempotent rebuild, where the
        // reverse order would learn the key and never owe the replay.
        await _requireRebuild();
        await workspaceKeys.remember(workspaceId, record.epoch, epochKey);
        learned++;
      } on SyncRejection catch (rejection) {
        await _raiseAlarm(
          IntegrityAlarmKind.aeadFailure,
          detail: 'the KeyWrap served for epoch ${record.epoch} did not open under '
              'this Device\'s own KEX key: ${rejection.message}',
        );
      }
    }
    return learned;
  }

  /// Re-receive the ops quarantined for a key that has since arrived.
  ///
  /// The healing half of [SyncRejectionReason.missingEpochKey]. Released *after*
  /// [_receive] returns, which is the opposite of the chain-successor scan and for
  /// a reason that scan does not share: this one walks a list fetched once, so
  /// nothing about termination depends on the row leaving the unreleased set
  /// early, while `_releaseChainSuccessors` re-queries the unreleased rows every
  /// iteration and would loop for ever without it.
  ///
  /// The ordering matters because [_receive] rethrows [SqliteException] rather
  /// than quarantining it — a storage failure is about *our* database, not the
  /// envelope. Releasing first would drop the row out of this scan while the
  /// cursor has already moved past the op, so the envelope would exist nowhere
  /// and the write would be lost. A re-receive that *refuses* still returns
  /// normally, having quarantined a fresh row, so releasing afterwards keeps the
  /// "never re-examined for ever" property the early release was there for.
  Future<Set<AffectedEntity>> _releaseOpsAwaitingEpochKeys() async {
    final rows = await (_db.select(_db.quarantinedOps)
          ..where((row) =>
              row.workspaceId.equals(workspaceId) &
              row.releasedAt.isNull() &
              row.reason.equals(SyncRejectionReason.missingEpochKey.code))
          ..orderBy([(row) => OrderingTerm(expression: row.id)]))
        .get();
    final affected = <AffectedEntity>{};
    for (final row in rows) {
      final seq = row.seq;
      if (seq == null) continue;
      final OpHeader header;
      try {
        header = OpHeader.parse(splitEnvelope(row.envelope).header);
      } on SyncRejection {
        continue;
      }
      if (await workspaceKeys.keyFor(workspaceId, header.keyEpoch) == null) continue;
      affected.addAll(await _receive(PulledOp(seq: seq, envelope: row.envelope)));
      await _markReleased(row.id);
    }
    return affected;
  }

  /// Re-receive the ops quarantined at an epoch the floor has since reached.
  ///
  /// The healing half of [SyncRejectionReason.keyEpochUnknown], and deliberately
  /// **not** [_releaseOpsAwaitingEpochKeys]. That scan gates release on holding the
  /// key — already true for a future-epoch op, since `refreshEpochKeys` fetches
  /// every epoch the server holds — so filing a future-epoch op under
  /// [SyncRejectionReason.missingEpochKey] would release, re-refuse and
  /// re-quarantine it on every pull. What heals a future-epoch refusal is the
  /// **floor rising** to reach the op's epoch, a different predicate.
  ///
  /// Only runs when a `rotate` raised the floor this pull ([_epochFloorRaised]), so
  /// a quarantined op whose epoch is still unreached is not re-examined on pulls
  /// where nothing changed. Even when it does run, an op still above the (now higher
  /// but not yet high enough) floor is skipped rather than re-received, so a rotate
  /// that raised the floor part-way toward the op's epoch never churns it.
  ///
  /// The `_receive`-then-`_markReleased` ordering, and the `SqliteException` rethrow
  /// it depends on, are [_releaseOpsAwaitingEpochKeys]'s for the same reason: a
  /// storage fault must not drop the row out of the scan with the cursor already
  /// past the op.
  Future<Set<AffectedEntity>> _releaseOpsAwaitingEpoch() async {
    // Read once: the floor cannot change during this scan. The rows are filtered
    // to `keyEpochUnknown` (content/compaction-only), so no nested rotate can
    // raise it mid-loop, and `_receive` on those rows never moves it either.
    final floor = await epochFloor();
    final rows = await (_db.select(_db.quarantinedOps)
          ..where((row) =>
              row.workspaceId.equals(workspaceId) &
              row.releasedAt.isNull() &
              row.reason.equals(SyncRejectionReason.keyEpochUnknown.code))
          ..orderBy([(row) => OrderingTerm(expression: row.id)]))
        .get();
    final affected = <AffectedEntity>{};
    for (final row in rows) {
      final seq = row.seq;
      if (seq == null) continue;
      final OpHeader header;
      try {
        header = OpHeader.parse(splitEnvelope(row.envelope).header);
      } on SyncRejection {
        continue;
      }
      // Still above the floor: the rotate that raised it did not reach this op's
      // epoch. Leave it quarantined rather than re-receive it into a fresh refusal.
      if (header.keyEpoch > floor) continue;
      affected.addAll(await _receive(PulledOp(seq: seq, envelope: row.envelope)));
      await _markReleased(row.id);
    }
    return affected;
  }

  /// Re-receive the ops refused for an author key this device did not know.
  ///
  /// The healing half of [SyncRejectionReason.memberNotChainedToRoot]: a device
  /// that refused a peer's change because its directory of other devices' keys
  /// was empty applies that change once it knows the author's key again. The
  /// rows are already here — a refusal quarantines the envelope and the pull
  /// cursor moves past it, so the server never serves it again.
  ///
  /// The per-row gate decides only *whether to ask again*. The ordinary receive
  /// pipeline then decides the row's fate with no check skipped: signature,
  /// decrypt, shape, chain and grant all run again. A key Root never vouched for
  /// therefore stays refused — the gate skips that row, so the pipeline is
  /// never asked about it, the row keeps its reason and stays unreleased, and
  /// no second row is filed.
  ///
  /// `_receive` comes before `_markReleased` for the reason
  /// [_releaseOpsAwaitingEpochKeys] gives: `_receive` rethrows
  /// [SqliteException] rather than quarantining it, so a storage fault must not
  /// drop the row out of this scan with the cursor already past the op. A
  /// re-receive that *refuses* returns normally, having quarantined a fresh row
  /// under the true reason; this row is then stamped released, so the scan does
  /// not examine it again.
  ///
  /// A **control** op re-admitted here carries two follow-ons the content path
  /// gets for free and the control path does not: its authority can change the
  /// grant verdict of content already judged, and it occupies a position in its
  /// author's chain, so the successors held behind it are released with it.
  Future<Set<AffectedEntity>> _releaseOpsAwaitingMemberRegistration() async {
    final rows = await (_db.select(_db.quarantinedOps)
          ..where((row) =>
              row.workspaceId.equals(workspaceId) &
              row.releasedAt.isNull() &
              row.reason.equals(SyncRejectionReason.memberNotChainedToRoot.code))
          ..orderBy([(row) => OrderingTerm(expression: row.id)]))
        .get();
    final affected = <AffectedEntity>{};
    for (final row in rows) {
      final seq = row.seq;
      if (seq == null) continue;
      final OpHeader header;
      try {
        header = OpHeader.parse(splitEnvelope(row.envelope).header);
      } on SyncRejection {
        continue;
      }
      // The author's key is unknown here, so the refusal stands — but only for
      // now: a device that learns the key asks again on the next pull that
      // learned one.
      if (!directory.hasSigningKeyFor(header.authorMemberId, header.authorKeyId)) {
        continue;
      }
      affected.addAll(await _receive(PulledOp(seq: seq, envelope: row.envelope)));
      // A control op admitted late does two things the content path gets for
      // free and the control path does not. Both run **before** the row is
      // stamped released: the unreleased row is the durable record that they
      // are owed, so a fault or a kill between here and the stamp makes the next
      // scan do them again (re-receiving a logged op is a no-op) instead of
      // dropping the row out of the scan with the obligation unmet.
      if (header.opClass == opClassControl) {
        // Its authority can change the grant verdict of content already judged
        // at a later `seq`; the tail's existing `rebuildFromOpLog` recomputes
        // exactly that verdict.
        await _requireRebuild();
        // A control op occupies a position in its author's chain, but the
        // control branch of `_receive` returns without asking whether a held
        // successor is now valid — the content and prune branches end in
        // `_releaseChainSuccessors` and this one does not. Without this call,
        // content held as `author_chain_gap` behind a re-admitted control op
        // stays held.
        affected.addAll(await _releaseChainSuccessors(header.authorMemberId));
      }
      await _markReleased(row.id);
    }
    return affected;
  }

  /// Re-receive the control ops refused because their predecessor was not applied.
  ///
  /// The healing half of the *positional* [SyncRejectionReason.controlChainBreak]:
  /// a control op naming a predecessor this device had not applied yet. A zero
  /// link or a genesis with a link is a shape break, permanent by construction,
  /// and never passes the gate.
  ///
  /// The gate decides only *whether to ask again*; it verifies nothing. The row's
  /// `op_log` slot must hold the op's own bytes, unapplied and refused for this
  /// reason — a positional break is *logged but refused*, and a row refused
  /// before it was logged is not this scan's row. The row's `prev_control_hash`
  /// must then name an op in the applied control log, and the row must sit
  /// above the op it names: the applied log is ordered by transport `seq` and
  /// its last row is the chain head, so an op slotted *under* the op it names
  /// would leave `applied.last` reading as that op rather than as the new tip.
  /// What happens to the row then is decided where it would be live: an op
  /// naming the head is an ordinary append, and an op naming an earlier applied
  /// op takes the fork path and is settled by tie-break, so that a device which
  /// saw it before its rival and a device which saw it after keep the same
  /// branch.
  ///
  /// Calling [_receive] on the row is not enough. A positional break is
  /// logged-but-refused, so the `op_log` slot holds the op's own bytes and
  /// [_logReceived] would read a second receipt as a re-serve and skip it —
  /// the row would be stamped released with nothing applied. The scan passes
  /// `reclaimRefusedControlSlot`, which takes the slot back inside the receive
  /// transaction. Verification, authority, position and fork resolution all run
  /// again.
  ///
  /// `_receive` comes before `_markReleased`, for the reason
  /// [_releaseOpsAwaitingEpochKeys] gives. What the re-receive decided is
  /// **told** by `_receive`, not read back from `op_log`: a refusal raised
  /// while verifying — a signature, a certificate, a grant, an authority —
  /// never reaches the transaction, so the slot keeps the verdict that
  /// refused the op the first time and cannot say what the second attempt
  /// found. Still a positional break leaves the row unreleased; an applied op,
  /// or a different refusal (which `_receive` has already filed under its true
  /// reason), stamps it released.
  ///
  /// A row the User has refused for good is not examined at all: their decision
  /// is the end of the question, so the scan skips it and the op stays refused.
  ///
  /// A row whose slot carries a verdict **other** than the break is not asked
  /// about again: the re-examination reached one, and the row is the break it
  /// replaced. The refusal that replaced it is filed by `_receive`, in a second
  /// transaction after the receive transaction commits, so a storage fault
  /// between the two can leave the slot carrying the verdict, the refusal
  /// unfiled and this row unreleased — which is what
  /// [_replaceRefusedBreak] recovers.
  Future<Set<AffectedEntity>> _releaseOpsAwaitingControlPredecessor() async {
    final rows = await (_db.select(_db.quarantinedOps)
          ..where((row) =>
              row.workspaceId.equals(workspaceId) &
              row.releasedAt.isNull() &
              row.resolution.isNull() &
              row.reason.equals(SyncRejectionReason.controlChainBreak.code))
          ..orderBy([(row) => OrderingTerm(expression: row.id)]))
        .get();
    final affected = <AffectedEntity>{};
    for (final row in rows) {
      final seq = row.seq;
      if (seq == null) continue;
      // Parse the control op to get its author for chain successor release, and
      // the predecessor it names, for the detail a replaced break is filed
      // under.
      final OpHeader header;
      final ControlPayload payload;
      try {
        final parts = splitEnvelope(row.envelope);
        header = OpHeader.parse(parts.header);
        payload = ControlPayload.decode(parseBody(parts.body));
      } on SyncRejection {
        continue;
      }
      // The `op_log` slot is what makes this row worth re-examining. A control
      // op refused at the position check is *logged but refused*, so the slot
      // holds the op's own bytes with the refusal stamped on it. A row refused
      // before it was logged — a shape break, or a registering op that is not
      // its author's first — has no slot at all, and shares this row's reason
      // with a break that can heal. It is not this scan's row: it was never
      // waiting for a predecessor, and asking again would re-run the same
      // verdict for ever.
      final slot = await _opLogRowAt(seq);
      if (slot == null || !sameBytes(slot.envelope, row.envelope)) continue;
      if (slot.appliedAt != null) {
        // Applied already (a stop between the receive commit and the stamp, or a
        // failed read-back): nothing to apply, but the rebuild is still owed.
        await _requireRebuild();
        _releaseAfterRebuild.add(row.id);
        // Control op already applied; release its author's chain successors.
        affected.addAll(await _releaseChainSuccessors(header.authorMemberId));
        continue;
      }
      final slotVerdict = slot.refusedReason;
      if (slotVerdict != null &&
          slotVerdict != SyncRejectionReason.controlChainBreak.code) {
        // The slot holds these bytes and carries a verdict **other** than the
        // break: the re-examination reached one, and this row is the break it
        // replaced. The verdict is stamped inside the receive transaction and
        // the refusal it reached is filed in a second one, so a storage fault
        // between the two leaves the slot carrying the verdict, the refusal
        // unfiled and this row unreleased — and a guard on the reason would
        // skip the row for ever. So the row is reached here.
        await _replaceRefusedBreak(row, slotVerdict, payload, header);
        continue;
      }
      if (!await _namesAppliedPredecessor(row.envelope, seq)) continue;
      // The verdict the re-examination reaches, told by `_receive` rather than
      // read back from the slot.
      SyncRejection? refusal;
      affected.addAll(await _receive(
        PulledOp(seq: seq, envelope: row.envelope),
        reclaimRefusedControlSlot: true,
        onRefused: (verdict) => refusal = verdict,
      ));
      final after = await _opLogRowAt(seq);
      if (after == null) continue;
      // Verify the envelope identity: the read-back op_log row must be for the
      // same envelope we're examining, or its verdict is for a different op.
      if (!sameBytes(after.envelope, row.envelope)) continue;
      if (after.appliedAt != null) {
        // Its authority can change the grant verdict of content already judged at
        // a later `seq`; the tail's `rebuildFromOpLog` recomputes that verdict.
        // Control op newly admitted; release its author's chain successors.
        await _requireRebuild();
        _releaseAfterRebuild.add(row.id);
        affected.addAll(await _releaseChainSuccessors(header.authorMemberId));
        continue;
      }
      final verdict = refusal;
      if (verdict == null ||
          verdict.reason == SyncRejectionReason.controlChainBreak) {
        // No verdict, or the same positional break again: the slot was not in the
        // state the reclaim needs, or the position check still fails. The op is
        // still waiting for its predecessor, so it stays in the set.
        continue;
      }
      // A different guard refused it. The break is answered — the op cannot
      // apply — and the row `_receive` filed carries the true reason. This row
      // is released, or the scan would ask again on every pull that applies a
      // control op, and re-run the accusation each time.
      await _markReleased(row.id);
    }
    return affected;
  }

  /// Retire a break row that a later verdict replaced, filing that verdict if
  /// it was never filed.
  ///
  /// The re-examination's verdict is stamped on the `op_log` slot inside the
  /// receive transaction, and the refusal it reached is filed in a second one
  /// ([_refuse]). A storage fault between the two leaves the slot carrying the
  /// new verdict, the replacement refusal unfiled and the break row unreleased
  /// — and the scan would then skip the row for ever, because the slot no
  /// longer carries the break it is here to heal.
  ///
  /// So the row is reached: the replacement refusal is filed from the verdict
  /// the slot carries — the stamp the receive transaction committed, which is
  /// the verdict the re-examination reached — and the break row is retired.
  /// The op itself is not touched: it stays refused, and the refusal that
  /// replaced the break says why.
  Future<void> _replaceRefusedBreak(
    QuarantineRow row,
    String verdictCode,
    ControlPayload payload,
    OpHeader header,
  ) async {
    final seq = row.seq;
    if (seq == null) return;
    final reason = SyncRejectionReason.values
        .where((candidate) => candidate.code == verdictCode)
        .firstOrNull;
    // A code this build does not know: the stamp is not a verdict it can file,
    // and the row is left alone rather than retired on a guess.
    if (reason == null) return;
    final replacement = await _refusalRowAt(seq, reason, row.envelope);
    if (replacement == null) {
      // The replacement was never filed: the fault hit `_refuse`'s own insert.
      // File it now, under the verdict the slot carries.
      await _refuse(
        PulledOp(seq: seq, envelope: row.envelope),
        SyncRejection(reason, _verdictDetail(seq, reason, payload)),
        header,
      );
    } else {
      // The refusal is filed. The alarm it raises is a second step of
      // `_refuse`, and a fault between the two leaves the accusation unraised:
      // raise it now, with the detail the filed refusal carries — and only when
      // no alarm for it was ever raised, so an answer the User has already
      // given is not taken back. A refusal the User has answered raises
      // nothing, which is the rule `_refuse` follows.
      final kind = alarmForRejection(reason);
      if (kind != null &&
          replacement.resolution == null &&
          !await _hasRaisedAlarm(kind, header.authorMemberId)) {
        await _raiseAlarm(
          kind,
          detail: replacement.detail,
          authorMemberId: header.authorMemberId,
          quarantineOpRowId: replacement.id,
        );
      }
    }
    // The break is answered: the op cannot apply, and the refusal that
    // replaced it is filed. Retiring the row keeps the scan from asking about
    // it again.
    await _markReleased(row.id);
  }

  /// The detail a refusal filed under [reason] carries.
  ///
  /// The fork's detail is the receive path's own text, so an accusation the
  /// User reads says the same thing whether the refusal was filed by the
  /// receive or recovered by the scan.
  String _verdictDetail(
    int seq,
    SyncRejectionReason reason,
    ControlPayload payload,
  ) =>
      reason == SyncRejectionReason.controlChainFork
          ? _forkRefusalDetail(seq, payload.prevControlHash)
          : 'control op at seq $seq was refused as ${reason.code}';

  /// The refusal filed for these bytes under [reason] at [seq], released or not.
  ///
  /// Released rows count: a refusal the User has already dealt with was still
  /// filed, and filing it again would accuse a second time about a change that
  /// has already been answered.
  Future<QuarantineRow?> _refusalRowAt(
    int seq,
    SyncRejectionReason reason,
    Uint8List envelope,
  ) async {
    final rows = await (_db.select(_db.quarantinedOps)
          ..where((row) =>
              row.workspaceId.equals(workspaceId) &
              row.seq.equals(seq) &
              row.reason.equals(reason.code)))
        .get();
    for (final row in rows) {
      if (sameBytes(row.envelope, envelope)) return row;
    }
    return null;
  }

  /// Whether an alarm of [kind] has ever been raised for [authorMemberId].
  ///
  /// Unlike [_standingAlarm], a resolved alarm counts: this asks whether the
  /// accusation was ever made, not whether it still stands. A User's answer is
  /// not taken back because a scan recovered the refusal it was raised for.
  Future<bool> _hasRaisedAlarm(
    IntegrityAlarmKind kind,
    String? authorMemberId,
  ) async {
    final rows = await (_db.select(_db.integrityAlarms)
          ..where((row) =>
              row.workspaceId.equals(workspaceId) &
              row.kind.equals(kind.code) &
              (authorMemberId == null
                  ? row.authorMemberId.isNull()
                  : row.authorMemberId.equals(authorMemberId))))
        .get();
    return rows.isNotEmpty;
  }

  /// Whether [envelope], held at [seq], is a control op that names a predecessor
  /// this device has applied. Advisory only: see
  /// [_releaseOpsAwaitingControlPredecessor].
  ///
  /// The predecessor's being applied is what makes the op worth asking about
  /// again. What happens to it is **not** decided here. Two things are, and both
  /// are about **order**:
  ///
  ///  * The op has to sit **above** the op it names. The applied log is ordered
  ///    by transport `seq` and its last row is the chain head, so an op slotted
  ///    under the op it names would leave `applied.last` reading as that op
  ///    rather than as the new tip — and every op chained after it would then be
  ///    refused, because the head this device offers is one step behind the one
  ///    the chain is on. A server that hands out a lower `seq` for an op than
  ///    the op it names produces exactly that, and the op stays refused.
  ///  * Nothing about the fork. An op naming the **head** is an ordinary
  ///    append; an op naming an **earlier** applied op is a fork candidate, and
  ///    the tie-break in [_resolveControlPosition] settles it: the branch it
  ///    beats is quarantined, and the branch it loses is quarantined instead.
  ///
  /// Refusing every fork candidate here would decide the fork wrongly: a device
  /// that saw the op *before* its rival would keep the rival's branch for ever,
  /// while a device that saw it after would take the op's. The tie-break is
  /// total and order-independent, so it is the one place that decides, and it is
  /// the same answer whichever order the two ops arrived in.
  Future<bool> _namesAppliedPredecessor(Uint8List envelope, int seq) async {
    final ControlPayload payload;
    try {
      final parts = splitEnvelope(envelope);
      final header = OpHeader.parse(parts.header);
      if (header.opClass != opClassControl) return false;
      payload = ControlPayload.decode(parseBody(parts.body));
    } on SyncRejection {
      return false;
    }
    final applied = await _appliedControlLog(includeQuarantined: false);
    if (applied.isEmpty) return false;
    // The applied op this one names: its predecessor.
    final predecessor = applied
        .where((row) => sameBytes(row.payloadHash, payload.prevControlHash))
        .firstOrNull;
    if (predecessor == null) return false;
    // It has to sit above the op it names. Above the head, when it names the
    // head — the ordinary append — and above an earlier op, when it names one:
    // the tie-break settles which of the two branches survives, and the winner
    // becomes the new head, so the winner has to be the last row of the log.
    return seq > predecessor.seq;
  }

  Future<OpLogRow?> _opLogRowAt(int seq) => (_db.select(_db.opLog)
        ..where((row) => row.workspaceId.equals(workspaceId) & row.seq.equals(seq)))
      .getSingleOrNull();

  /// Take back the `op_log` slot of a control op refused as a positional
  /// [SyncRejectionReason.controlChainBreak], so it can be applied.
  ///
  /// Returns true only when the slot holds exactly this op's bytes, unapplied,
  /// refused for that reason; the refusal stamp is then cleared and the caller
  /// goes on to apply it. Any other state returns false and the op ends there, as
  /// a taken slot does. Runs inside the receive transaction.
  Future<bool> _reclaimRefusedControlSlot(PulledOp pulled) async {
    final existing = await _opLogRowAt(pulled.seq);
    if (existing == null ||
        !sameBytes(existing.envelope, pulled.envelope) ||
        existing.appliedAt != null ||
        existing.refusedReason != SyncRejectionReason.controlChainBreak.code) {
      return false;
    }
    // The user may have permanently rejected this op via quarantined_ops.resolution.
    // Re-read it in this transaction; if set, the decision is final and the op
    // stays refused.
    //
    // Read every row at this seq, not one: a server that hands out the same
    // transport seq twice leaves two refusals here, and the decision belongs to
    // the row for *these* bytes — a decision about another op at the same seq
    // is about another op.
    final quarantined = await (_db.select(_db.quarantinedOps)
          ..where((row) =>
              row.workspaceId.equals(workspaceId) &
              row.seq.equals(pulled.seq) &
              row.reason.equals(SyncRejectionReason.controlChainBreak.code)))
        .get();
    if (quarantined.any((row) =>
        sameBytes(row.envelope, pulled.envelope) && row.resolution != null)) {
      return false;
    }
    await _clearRefused(pulled.seq);
    return true;
  }

  /// Whether this device is at a keyed epoch whose key it does not hold — the
  /// state-based half of the refresh trigger, and the restart-safe form of
  /// [_epochKeyRefreshRequired].
  ///
  /// A `rotate` raises the floor and sets that flag in memory, and the pull tail
  /// fetches the wraps on the strength of it. A device that exits between the
  /// rotate applying and the fetch comes back with the flag cleared, and with no
  /// quarantine row to fetch from either: nothing has been received at the new
  /// epoch yet, so nothing has been refused for a missing key. The device would
  /// sit at its own current epoch without the key for it, and every local
  /// capture would be refused as `missing_epoch_key`, until some peer's op
  /// happened to quarantine and fetch.
  ///
  /// So the obligation is read from the state rather than remembered: a floor
  /// above zero means this device's own control log established a keyed epoch,
  /// and the key for it is a wrap the server holds for this Member. The fetch is
  /// one round-trip per pull, the same bound the flag-triggered fetch has.
  Future<bool> _lacksCurrentEpochKey() async {
    final floor = await epochFloor();
    if (floor <= 0) return false;
    return await workspaceKeys.keyFor(workspaceId, floor) == null;
  }

  /// Whether anything is still waiting on a key — the state-based half of the
  /// refresh trigger.
  ///
  /// Read from the quarantine rather than from a flag, so a device that was offline
  /// when the wrap was published retries on its next pull instead of only on the
  /// pull that first saw the gap.
  Future<bool> _hasOpsAwaitingEpochKeys() async {
    final rows = await (_db.select(_db.quarantinedOps)
          ..where((row) =>
              row.workspaceId.equals(workspaceId) &
              row.releasedAt.isNull() &
              row.reason.equals(SyncRejectionReason.missingEpochKey.code))
          ..limit(1))
        .get();
    return rows.isNotEmpty;
  }

  /// Whether anything is still waiting on the floor rising — the state-based half
  /// of the future-epoch release trigger, and the counterpart to
  /// [_hasOpsAwaitingEpochKeys].
  ///
  /// It exists for the same reason that one does: the transient [_epochFloorRaised]
  /// flag is set inside `_applyControlOp` and consumed at the end of the *same*
  /// `pull()`, so a device torn down after a rotate has durably raised the floor but
  /// before the release scan ran would lose the trigger. Nothing else calls
  /// [_releaseOpsAwaitingEpoch], so the quarantined future-epoch op would sit stuck
  /// until an unrelated later rotation happened to re-arm the flag — or for ever if
  /// the Workspace never rotated again. Reading the quarantine on every pull while a
  /// row is pending costs only a bounded `LIMIT 1`, and the per-row floor check in
  /// [_releaseOpsAwaitingEpoch] already leaves still-too-high rows quarantined
  /// without re-receiving them, so this reintroduces none of the churn AC-4 forbids.
  Future<bool> _hasOpsAwaitingEpoch() async {
    final rows = await (_db.select(_db.quarantinedOps)
          ..where((row) =>
              row.workspaceId.equals(workspaceId) &
              row.releasedAt.isNull() &
              row.reason.equals(SyncRejectionReason.keyEpochUnknown.code))
          ..limit(1))
        .get();
    return rows.isNotEmpty;
  }

  // --- epoch_floor ------------------------------------------------------------

  /// The monotone `key_epoch` floor for this Workspace. Absent reads as 0.
  Future<int> epochFloor() async {
    final row = await (_db.select(_db.epochFloors)
          ..where((r) => r.workspaceId.equals(workspaceId)))
        .getSingleOrNull();
    return row?.keyEpochFloor ?? 0;
  }

  /// When the current epoch was established, as the **log** records it.
  ///
  /// The `rotated_at_hlc` of the latest applied `rotate`, or the genesis's
  /// `created_at_hlc` for a Workspace that has never rotated. Read from the signed
  /// control ops rather than from `epoch_floors.raised_at`, because that column
  /// stamps *this device's* local clock at the moment it applied the op — two
  /// devices would then disagree about the epoch's age, and a device that enrolled
  /// yesterday would think a two-year-old epoch was a day old.
  ///
  /// Null before any control op has applied.
  Future<DateTime?> currentEpochEstablishedAt() async {
    final rows = await _appliedControlLog();
    for (final row in rows.reversed) {
      if (row.controlType == controlTypeRotate) {
        return DateTime.fromMillisecondsSinceEpoch(row.certWallMs, isUtc: true);
      }
    }
    for (final row in rows) {
      if (row.controlType == controlTypeWorkspaceGenesis) {
        return DateTime.fromMillisecondsSinceEpoch(row.certWallMs, isUtc: true);
      }
    }
    return null;
  }

  /// Raise the floor, clamping to the maximum ever seen.
  ///
  /// **Raise-only by construction**: a request to lower it is silently the
  /// no-op it has to be, because a floor that could fall would let a rotation be
  /// undone by an older op — which is the whole thing the floor prevents. #554's
  /// verified `rotate` control op is the only production caller; until then this
  /// is exercised through the API and across restart.
  Future<int> raiseEpochFloor(int keyEpoch) async {
    final current = await epochFloor();
    final raised = keyEpoch > current ? keyEpoch : current;
    await _db.into(_db.epochFloors).insertOnConflictUpdate(
          EpochFloorsCompanion.insert(
            workspaceId: workspaceId,
            keyEpochFloor: raised,
            raisedAt: _now(),
          ),
        );
    return raised;
  }


  /// Append to the log, or record that the append itself was refused.
  ///
  /// A **plain insert, never an upsert.** The log is evidence, and evidence is
  /// not edited: a row already at this position is a second claim on a slot this
  /// device has spent, so a server serving two different chain-valid ops under
  /// one transport `seq` must not be able to replace the first with the second.
  /// The uniqueness constraints are the authority on that — `(workspace, seq)`
  /// for the transport position, the `op_log_author_chain` index for the chain
  /// position.
  ///
  /// Returns false when the op could not be logged and must be skipped. A taken
  /// slot is the only failure that ends there: it is an integrity event to
  /// surface and skip, because throwing would abort the rest of the page and let
  /// one poisoned position stall every op behind it. Every **other** database
  /// failure propagates and aborts the pull with the cursor unmoved — a
  /// transient `SQLITE_BUSY` is an op the next sync retries, not one permanently
  /// skipped under a slot-collision label it never earned.
  Future<bool> _logReceived(
    PulledOp pulled,
    OpHeader header, {
    DateTime? appliedAt,
  }) async {
    try {
      await _db.into(_db.opLog).insert(
            OpLogCompanion.insert(
              seq: pulled.seq,
              workspaceId: workspaceId,
              envelope: pulled.envelope,
              opId: header.opId,
              authorMemberId: header.authorMemberId,
              authorSeq: header.authorSeq,
              receivedAt: _now(),
              appliedAt: Value(appliedAt),
            ),
          );
      return true;
    } on SqliteException catch (error) {
      if (!_slotTakenResultCodes.contains(error.extendedResultCode)) rethrow;
      // Our own already-committed reserve, re-served because the cursor save
      // ([pull]'s [_saveCursor]) never landed before a crash: the row at this
      // transport seq is byte-identical to what we are re-serving. Skip silently —
      // it is already logged and, under the receive-path transaction wrap, already
      // fully applied. No alarm, and the caller returns `{}` so nothing re-applies;
      // the cursor then advances on the next pull and self-heals. The same
      // `(workspaceId, seq)` byte-compare [_refuseStaleServe] uses.
      final existing = await (_db.select(_db.opLog)
            ..where((row) =>
                row.workspaceId.equals(workspaceId) & row.seq.equals(pulled.seq)))
          .getSingleOrNull();
      if (existing != null && sameBytes(existing.envelope, pulled.envelope)) {
        return false;
      }
      // Divergent bytes at one transport seq (a genuine double-serve), or a real
      // author-chain slot collision on the `(authorMemberId, authorSeq)` unique
      // index with no byte-identical row at `pulled.seq`: the accusation stands,
      // exactly as before.
      await _raiseAlarm(
        IntegrityAlarmKind.authorChainSlotCollision,
        authorMemberId: header.authorMemberId,
        detail: 'author_seq ${header.authorSeq} could not be logged at seq '
            '${pulled.seq}: $error',
      );
      return false;
    }
  }

  Future<void> _stampApplied(int seq) async {
    await (_db.update(_db.opLog)
          ..where((row) => row.workspaceId.equals(workspaceId) & row.seq.equals(seq)))
        .write(OpLogCompanion(appliedAt: Value(_now())));
  }

  Future<void> _stampRefused(int seq, SyncRejectionReason reason) async {
    await (_db.update(_db.opLog)
          ..where((row) => row.workspaceId.equals(workspaceId) & row.seq.equals(seq)))
        .write(OpLogCompanion(refusedReason: Value(reason.code)));
  }

  /// Quarantine a refusal and raise whatever accusations it stands for.
  ///
  /// [servingAccusation] is what the *serving* is accused of independently of the
  /// bytes — only [_refuseStaleServe] has one. Accusations are collected by kind
  /// before any is raised, so one refused op bumps a kind's occurrence count once
  /// even when both routes arrive at the same accusation.
  ///
  /// **A refusal the user has already answered raises nothing.** The row the
  /// refusal is filed under carries the decision, and a server re-serving the
  /// same bytes must not put the accusation back in front of the user: the
  /// decision was about those bytes. The accusation about the *serving* is a
  /// separate matter and still stands — it is not about the refused change, it
  /// is about how the server offered it.
  Future<void> _refuse(
    PulledOp pulled,
    SyncRejection rejection,
    OpHeader? header, {
    ({IntegrityAlarmKind kind, String detail})? servingAccusation,
  }) async {
    final quarantineRow = await _quarantine(pulled, rejection, header);
    final accusations = <IntegrityAlarmKind, String>{};
    if (servingAccusation != null) {
      accusations[servingAccusation.kind] = servingAccusation.detail;
    }
    final escalated = alarmForRejection(rejection.reason);
    if (escalated != null && quarantineRow.resolution == null) {
      accusations.putIfAbsent(escalated, () => rejection.message);
    }
    for (final accusation in accusations.entries) {
      await _raiseAlarm(
        accusation.key,
        authorMemberId: header?.authorMemberId,
        detail: accusation.value,
        quarantineOpRowId: quarantineRow.id,
      );
    }
  }

  /// Record one refused envelope, or bump the accusation it already produced.
  ///
  /// Dedupe lives here rather than in one caller so it is a property of every
  /// quarantine path: a server re-serving the same refused bytes on every sync
  /// raises the alarm's occurrence count instead of growing the table without
  /// bound. Returns the row the refusal is filed under, so the caller can see
  /// whether the user has already answered it.
  ///
  /// **The dedupe is one unit** (#989). The read and the insert below are a
  /// single step under the quarantine lock, so two callers that refuse the
  /// same op at the same time cannot both decide to insert and file one
  /// refusal twice.
  ///
  /// The lock is the whole of the concurrency here, and deliberately so: the
  /// store is per-device and this process is its only writer, so there is no
  /// second writer to serialise against. A database constraint would be the
  /// wrong tool — a unique index over `(workspace, seq, reason, envelope)`
  /// cannot be added without a migration that fails on the very duplicate rows
  /// this defect produced, and dropping those rows would lose the evidence
  /// they are.
  ///
  /// What the dedupe means is unchanged: **the op**, not the slot. Two
  /// different envelopes refused for the same reason at the same seq are two
  /// refusals and both are filed.
  Future<QuarantineRow> _quarantine(
    PulledOp pulled,
    SyncRejection rejection,
    OpHeader? header,
  ) =>
      _runQuarantineExclusive(() async {
        final existing = await (_db.select(_db.quarantinedOps)
              ..where((row) =>
                  row.workspaceId.equals(workspaceId) &
                  row.seq.equals(pulled.seq) &
                  row.reason.equals(rejection.reason.code) &
                  row.releasedAt.isNull()))
            .get();
        for (final row in existing) {
          if (sameBytes(row.envelope, pulled.envelope)) return row;
        }
        final rowId = await _db.into(_db.quarantinedOps).insert(
              QuarantinedOpsCompanion.insert(
                workspaceId: workspaceId,
                seq: Value(pulled.seq),
                reason: rejection.reason.code,
                detail: rejection.message,
                envelope: pulled.envelope,
                detectedAt: _now(),
                authorMemberId: Value(header?.authorMemberId),
                authorSeq: Value(header?.authorSeq),
              ),
            );
        return await (_db.select(_db.quarantinedOps)
              ..where((row) => row.id.equals(rowId)))
            .getSingle();
      });

  /// Run [body] under the quarantine lock, **waiting** (FIFO) for any in-flight
  /// quarantine to finish first.
  ///
  /// Built on the future-chain idiom `EnrolmentService` uses for its ceremony
  /// lock, because there is no `Mutex`/`synchronized` package in this codebase
  /// to lean on. The chain's tail swallows the body's error so a failed
  /// quarantine does not poison the next one's chain; the caller still sees it.
  Future<T> _runQuarantineExclusive<T>(Future<T> Function() body) {
    final next = _quarantineTail.then((_) => body());
    _quarantineTail = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  // --- Integrity alarms --------------------------------------------------------

  /// Raise [IntegrityAlarmKind.epochKeySetUnpublishable] for this Workspace.
  ///
  /// A narrow public seam so [_raiseAlarm] stays private: the rotation resume lives
  /// in `EnrolmentService` and holds a scoped client, and this is the one accusation
  /// it needs to file. `authorMemberId` is deliberately **null** — the condition
  /// accuses nobody, and the server was right to refuse.
  ///
  /// Because the upsert key is `(workspace, kind, author)`, every epoch of one
  /// Workspace shares one row: [detail] carries the most recent and
  /// `occurrenceCount` counts terminalisations. Acceptable, because at most one
  /// pending record is ever live in practice (`pending_rotation_store.dart`).
  ///
  /// [detail] must stand on its own for #584 — no reader should need this call site
  /// to interpret it.
  Future<void> raiseEpochKeySetUnpublishableAlarm({required String detail}) async {
    await _raiseAlarm(IntegrityAlarmKind.epochKeySetUnpublishable, detail: detail);
  }

  /// Raise [IntegrityAlarmKind.ownWriteRefusedPermanently] for this Workspace.
  ///
  /// Carries `authorMemberId` the way `own_writes_rollback` does — this *is* an
  /// own-writes accusation — and is epoch-agnostic, because the flush it comes from
  /// is one call per Workspace.
  Future<void> raiseOwnWriteRefusedPermanentlyAlarm({
    required String detail,
  }) async {
    await _raiseAlarm(
      IntegrityAlarmKind.ownWriteRefusedPermanently,
      detail: detail,
      authorMemberId: identity.memberId,
    );
  }

  /// Raise or re-raise one accusation, keyed by `(workspace, kind, author)`.
  ///
  /// Re-raising un-resolves: an accusation that stands again is not history.
  /// It also un-decides: the User's answer was about the accusation as it
  /// stood then, and a new accusation is a new question. The row keeps the
  /// answer only until the next time the accusation stands again.
  ///
  /// [repostFromAuthorSeq] is the author's chain position this device's writes
  /// would be reposted from, for the rollback alarm where the server lost
  /// writes it had acknowledged. Null for every other alarm, and null for the
  /// rollback raised when the server holds a position this device never wrote —
  /// there is no agreed position to repost from.
  Future<int> _raiseAlarm(
    IntegrityAlarmKind kind, {
    required String detail,
    String? authorMemberId,
    int? quarantineOpRowId,
    int? repostFromAuthorSeq,
  }) async {
    final now = _now();
    final existing = await (_db.select(_db.integrityAlarms)
          ..where((row) =>
              row.workspaceId.equals(workspaceId) &
              row.kind.equals(kind.code) &
              (authorMemberId == null
                  ? row.authorMemberId.isNull()
                  : row.authorMemberId.equals(authorMemberId)))
          ..limit(1))
        .get();
    if (existing.isNotEmpty) {
      final alarm = existing.first;
      await (_db.update(_db.integrityAlarms)..where((row) => row.id.equals(alarm.id)))
          .write(IntegrityAlarmsCompanion(
        detail: Value(detail),
        occurrenceCount: Value(alarm.occurrenceCount + 1),
        lastDetectedAt: Value(now),
        resolvedAt: const Value(null),
        quarantineOpRowId: Value(alarm.quarantineOpRowId ?? quarantineOpRowId),
        resolution: const Value(null),
        resolutionDecidedAt: const Value(null),
        repostFromAuthorSeq: Value(repostFromAuthorSeq),
      ));
      return alarm.id;
    }
    return _db.into(_db.integrityAlarms).insert(
          IntegrityAlarmsCompanion.insert(
            workspaceId: workspaceId,
            kind: kind.code,
            authorMemberId: Value(authorMemberId),
            detail: detail,
            quarantineOpRowId: Value(quarantineOpRowId),
            occurrenceCount: 1,
            firstDetectedAt: now,
            lastDetectedAt: now,
            repostFromAuthorSeq: Value(repostFromAuthorSeq),
          ),
        );
  }

  /// Mark an accusation as no longer standing.
  Future<void> _resolveAlarm(IntegrityAlarmKind kind, String? authorMemberId) async {
    await (_db.update(_db.integrityAlarms)
          ..where((row) =>
              row.workspaceId.equals(workspaceId) &
              row.kind.equals(kind.code) &
              row.resolvedAt.isNull() &
              (authorMemberId == null
                  ? row.authorMemberId.isNull()
                  : row.authorMemberId.equals(authorMemberId))))
        .write(IntegrityAlarmsCompanion(resolvedAt: Value(_now())));
  }

  // --- Resolutions ------------------------------------------------------------

  /// Apply one held change, without checking where it sits in its author's
  /// chain.
  ///
  /// The fail-closed rule says a change from an author whose chain has a hole
  /// does not apply until the hole closes. **Taking upstream is the User
  /// breaking that rule on purpose**: this change's *position* is unverified,
  /// and every other check about it runs exactly as it does on the receive
  /// path — the author's signature over the bytes, the codec, the payload's
  /// shape, and the author's Grant at the change's own server seq.
  ///
  /// The chain verdict is the one check left out, and so is the `op_log`
  /// write: the change was refused, so it was never logged, and logging it now
  /// would put bytes in the log that the chain never vouched for. The row stays
  /// where it is — held, with no `released_at` — so the normal chain release
  /// still owns it: if the missing change ever arrives, the log heals and this
  /// re-apply is a no-op.
  ///
  /// Returns the entities the change touched. An **empty set means the change
  /// did not apply**: a refusal — corrupt bytes, a missing key, a revoked Grant
  /// — leaves the row exactly as it was.
  Future<Set<AffectedEntity>> _applyHeldChange(QuarantineRow row) async {
    try {
      final parts = splitEnvelope(row.envelope);
      final header = OpHeader.parse(parts.header);
      // The header gates the receive path applies before its chain verdict. A
      // held row can have been filed without them (a stale-serve refusal), so
      // they are asked again here, once, for every caller.
      header.checkServed();
      if (header.workspaceId != workspaceId) return const {};
      if (header.opClass != opClassContent &&
          header.opClass != opClassCompaction) {
        return const {};
      }
      if (header.authorMemberId != row.authorMemberId ||
          header.authorSeq != row.authorSeq) {
        return const {};
      }
      // This device's own position held with other bytes than the outbox has is
      // a divergence, and the local copy stands — the receive path refuses it
      // the same way, and taking upstream must not apply what it refuses.
      await _checkOwnWrites(header, row.envelope);
      final signPk =
          directory.publicKeyFor(header.authorMemberId, header.authorKeyId);
      await verifyEnvelope(row.envelope, signPk);
      final payload =
          await _decodeContentPayload(header, parts.header, parts.body);
      guardOpClassShape(payload, opClass: header.opClass);
      final seq = row.seq;
      // A held row with no transport seq has no position to read a Grant at,
      // and no position to be the log's own.
      if (seq == null) return const {};
      // The Grant is read at the change's **own** server seq, never against
      // current control state — the same rule the receive path follows.
      final authorization = (await grantsView()).verdictFor(
        authorMemberId: header.authorMemberId,
        opClass: header.opClass,
        seq: seq,
      );
      if (authorization != null) return const {};
      final affected = await _reducer.apply(
        payload,
        authorMemberIdHex: memberIdToHex(header.authorMemberId),
      );
      _clock.receive(payload.hlc);
      return affected;
    } on SyncRejection {
      return const {};
    }
  }

  /// Apply the changes the User decided to take from the server, and settle the
  /// accusation they were holding open.
  ///
  /// The decision is the User's: the server's chain is the one to keep, so the
  /// changes it holds are applied even though their position in that chain was
  /// never verified. Everything else about them is still checked — see
  /// [_applyHeldChange].
  ///
  /// The rows are stamped `took_upstream` and **stay held**: the change was
  /// never logged, and the chain release still owns the row, so the log heals
  /// on its own if the missing change ever arrives.
  ///
  /// The alarm is settled only when nothing is left undecided. A change that
  /// cannot be applied — corrupt bytes, a revoked Grant — leaves its row
  /// undecided, and an undecided row keeps the alarm standing: the User asked
  /// for the server's version, and the server's version could not be read.
  ///
  /// **The accusation is settled after the change has reached the domain
  /// store, not before.** The decision is the User's answer; it takes effect
  /// when the app shows the change. A projection that fails, or an app that is
  /// killed between the two moments, leaves the accusation standing and
  /// unanswered — so the answer is still on offer and the work is done again
  /// when the User gives it. Settling first would close the accusation over a
  /// change the User never saw, with nothing left to retry.
  Future<void> _takeUpstream(IntegrityAlarmRow alarm) async {
    final affected = <AffectedEntity>{};
    final now = _now();
    var complete = false;
    var stale = false;
    String? author;
    final decidedRowIds = <int>[];
    await _db.transaction(() async {
      // The accusation must still be the one the User answered: a refusal that
      // arrived while they were answering is a new question, not this one.
      final current = await _alarmRow(alarm.id);
      if (current == null || current.occurrenceCount != alarm.occurrenceCount) {
        stale = true;
        return;
      }
      author = current.authorMemberId;
      // The snapshot is taken inside the transaction, so the rows it stamps and
      // the rows the settlement asks about are the same rows.
      final held = await (_db.select(_db.quarantinedOps)
            ..where((t) => _takenUpstreamRows(
                  t,
                  authorMemberId: current.authorMemberId,
                ))
            ..orderBy([
              (row) => OrderingTerm(expression: row.authorSeq),
              (row) => OrderingTerm(expression: row.id),
            ]))
          .get();
      final decided = <int>{};
      // The decision is complete when every row **still held** has been
      // applied. A row the chain release has re-admitted is no longer the
      // decision's work: the release owns it now, and it went into the log
      // through the verified path. It is still applied here — the projection
      // may be the thing that never saw it — but it does not decide whether
      // the decision is complete.
      var heldCount = 0;
      var appliedHeldCount = 0;
      for (final row in held) {
        final stillHeld = row.releasedAt == null;
        if (stillHeld) heldCount++;
        final touched = await _applyHeldChange(row);
        if (touched.isEmpty) continue;
        affected.addAll(touched);
        decided.add(row.id);
        if (stillHeld) appliedHeldCount++;
        // A row the decision was already recorded on is not stamped twice: it
        // is the work of a take upstream whose projection did not finish, and
        // it is done again so the projection sees it this time.
        if (row.resolution != null) continue;
        await (_db.update(_db.quarantinedOps)..where((r) => r.id.equals(row.id)))
            .write(QuarantinedOpsCompanion(
          resolution: Value(AlarmResolution.tookUpstream.code),
          resolutionDecidedAt: Value(now),
        ));
      }
      complete = appliedHeldCount == heldCount;
      decidedRowIds.addAll(decided);
    });
    // The projection is the tail of the receive order, as it is at the end of a
    // pull: what the applied changes touched is projected once, and the
    // convergence passes run over what it changed.
    //
    // **A projection that fails leaves the accusation standing.** The error
    // travels to the caller, the rows keep the decision that was recorded on
    // them, and the alarm is still unanswered — so the User is asked again and
    // the work is done again. The settlement below is not reached.
    final projector = this.projector;
    if (projector != null) {
      final touched = await projector.project(affected);
      await _reconcileProjected(touched);
    }
    // The change is on the User's screen now, so the decision has taken
    // effect. The stamp is what tells the recovery there is nothing left to put
    // there — it is only written once the projection has succeeded — and it
    // commits **with** the settlement: an app stopped between the two would
    // leave an open accusation that no later pull looks at.
    await _db.transaction(() async {
      await _stampResolutionsProjected(decidedRowIds);
      // The change is in the domain store now, so the accusation is settled:
      // nothing is left to decide about this author — and so is the fork the
      // gap was holding open.
      if (complete && !stale) await _settleAuthorAlarms(author, now);
    });
    if (stale) {
      throw StateError(
        'the accusation changed while the answer was being recorded',
      );
    }
    // What was applied stays applied and projected. The ones that could not be
    // applied are said out loud, and their rows stay undecided.
    if (!complete) {
      throw StateError(
        'some of the changes that arrived could not be applied, so the '
        'accusation stands',
      );
    }
  }

  /// Stamp the rows whose take upstream has reached the domain store.
  Future<void> _stampResolutionsProjected(List<int> rowIds) async {
    if (rowIds.isEmpty) return;
    await (_db.update(_db.quarantinedOps)
          ..where((row) => row.id.isIn(rowIds)))
        .write(QuarantinedOpsCompanion(resolutionProjectedAt: Value(_now())));
  }

  /// Put on screen what a take upstream decided and never reached.
  ///
  /// A take upstream is work, not a note: the held change is applied to the
  /// reduced state and then projected into the domain store, and only the
  /// second half puts it on the User's screen. A projection that fails leaves
  /// the change reduced but unseen — and the work does not end there. The
  /// decision was recorded, so the accusation no longer offers the answer, and
  /// the retry that would do the work again excludes the row once the chain
  /// release has re-admitted it.
  ///
  /// So the work is retained until the projection succeeds: the row keeps its
  /// decision and its *lack* of a projection, and every pull walks the rows
  /// that are waiting. A pull that brings nothing new is enough — the recovery
  /// does not need a change to arrive.
  ///
  /// **The recovery projects the whole reduced state, not only the entities
  /// this decision named.** A failed projection takes the whole batch it was
  /// carrying with it, and the batch is not recoverable from the decision
  /// alone: those changes are in the reduced state and nowhere else. This is
  /// the same walk a rebuild from the log takes — `rebuildDomainFromOpLog` —
  /// and it leaves the entities with a local change still in the outbox alone,
  /// because their domain rows are ahead of merge state.
  Future<void> _recoverUnprojectedResolutions() async {
    final projector = this.projector;
    if (projector == null) return;
    final pending = await (_db.select(_db.quarantinedOps)
          ..where((row) =>
              row.workspaceId.equals(workspaceId) &
              row.resolution.equals(AlarmResolution.tookUpstream.code) &
              row.resolutionProjectedAt.isNull())
          ..orderBy([(row) => OrderingTerm(expression: row.id)]))
        .get();
    if (pending.isEmpty) return;
    final affected = <AffectedEntity>{};
    final touchedByRow = <int, Set<AffectedEntity>>{};
    for (final row in pending) {
      // The change is applied again, so the merge sees it and names its
      // entities. A row that no longer re-verifies — a Grant a corrected
      // control branch took away, bytes that cannot be read — applies nothing,
      // and **stays pending**: it is not stamped, so the accusation it holds
      // open is not closed over a change that is not there.
      final touched = await _applyHeldChange(row);
      if (touched.isEmpty) continue;
      touchedByRow[row.id] = touched;
      affected.addAll(touched);
    }
    if (touchedByRow.isEmpty) return;
    // The whole reduced state, so the changes that were in the batch the
    // failed projection was carrying reach the screen too.
    affected.addAll({
      for (final entity in await _reducedEntities())
        if (ownsCollection(entity.collection)) entity,
    });
    final touched = await projector.project(
      affected,
      leaveEntitiesAwaitingMerge: true,
    );
    await _reconcileProjected(touched);
    // An entity with a local change still in the outbox is left alone by this
    // walk, so a row whose change touched one has not reached the screen yet:
    // it stays pending until the outbox drain has merged and projected it.
    final awaitingMerge = await projector.entitiesAwaitingMerge();
    final projected = [
      for (final entry in touchedByRow.entries)
        if (!entry.value.any(awaitingMerge.contains)) entry.key,
    ];
    if (projected.isEmpty) return;
    final authors = {
      for (final row in pending)
        if (projected.contains(row.id)) row.authorMemberId,
    };
    // The marker and the settlement commit together, so an app stopped between
    // them cannot leave an open accusation that no later pull looks at.
    await _db.transaction(() async {
      await _stampResolutionsProjected(projected);
      for (final author in authors) {
        if (author == null) continue;
        await _settleAuthorAlarms(author, _now());
      }
    });
  }

  /// Settle the accusations this author's take upstream answered.
  ///
  /// The gap alarm the decision was about, and the fork it was holding open.
  /// Both are settled only when nothing they cover is left undecided.
  Future<void> _settleAuthorAlarms(String? author, DateTime now) async {
    await _db.transaction(() async {
      // A take upstream that has not reached the domain store is work still to
      // do: the accusation stands until it has.
      if (author != null && await _hasUnprojectedTakeUpstream(author)) return;
      final gap = await _standingAlarm(
        IntegrityAlarmKind.authorChainGap,
        author,
      );
      if (gap != null) {
        await _settleWhenNothingUndecided(
          alarm: gap,
          kind: IntegrityAlarmKind.authorChainGap,
          resolution: AlarmResolution.tookUpstream,
          now: now,
        );
      }
      final fork = await _standingAlarm(
        IntegrityAlarmKind.authorChainFork,
        author,
      );
      if (fork != null) {
        await _settleWhenNothingUndecided(
          alarm: fork,
          kind: IntegrityAlarmKind.authorChainFork,
          resolution: AlarmResolution.tookUpstream,
          now: now,
          forkHeadSeq: author == null
              ? null
              : await effectiveChainHeadSeq(author),
        );
      }
    });
  }

  /// Keep this device's own writes: mark them unsent again, so the next flush
  /// puts them back.
  ///
  /// The server had lost writes it had acknowledged, and the User has said
  /// this device's version is the one to keep. The work is to re-post those
  /// writes, and **the bytes are already signed**: the outbox rows from the
  /// position the server expects are marked unsent, so the next flush posts
  /// the very same envelopes. Nothing is rebuilt, re-signed or re-numbered —
  /// re-numbering this device's own chain is the one thing a rollback must
  /// never do.
  ///
  /// The decision is recorded and **the accusation stays standing**: the
  /// upload is still in flight, so the alarm is decided but unresolved, and
  /// the flush resolves it when the server acknowledges the re-send. That is
  /// the whole of "in progress" here — the bytes are queued, not the alarm
  /// quietly closed.
  ///
  /// **The answer is checked against the accusation inside the transaction,
  /// and the decision is stamped before the range is queued.** A flush can
  /// re-raise the accusation in the window between reading it and writing the
  /// answer, and the re-raise is a new question: it clears the decision and
  /// moves the agreed position. An answer about the older accusation must not
  /// queue the old position's range, and must not stamp the new accusation as
  /// decided. So the stamp is guarded by everything that makes this answer
  /// about the accusation as it stands — and a stamp that matches nothing
  /// leaves both the new accusation and the outbox exactly as they were.
  Future<void> _keepOurs(IntegrityAlarmRow alarm) async {
    final from = alarm.repostFromAuthorSeq;
    if (from == null) {
      throw StateError(
        'a rollback alarm with no agreed position offers no way to keep ours',
      );
    }
    final now = _now();
    var stale = false;
    await _db.transaction(() async {
      // The accusation must still be the one the User answered: a refusal that
      // arrived while they were answering is a new question, not this one —
      // and it may have moved the position the answer is about.
      final current = await _alarmRow(alarm.id);
      if (current == null ||
          current.occurrenceCount != alarm.occurrenceCount ||
          current.resolution != null ||
          current.repostFromAuthorSeq != from) {
        stale = true;
        return;
      }
      // The decision is stamped first, and the stamp is guarded by the same
      // facts: a re-raise that lands while this statement is being written
      // clears the decision and moves the position, and then the guard matches
      // nothing. Nothing is written, so the new accusation stands unanswered.
      final stamped = await (_db.update(_db.integrityAlarms)
            ..where((row) =>
                row.id.equals(alarm.id) &
                row.occurrenceCount.equals(alarm.occurrenceCount) &
                row.resolution.isNull() &
                row.repostFromAuthorSeq.equals(from)))
          .write(IntegrityAlarmsCompanion(
        resolution: Value(AlarmResolution.keptOurs.code),
        resolutionDecidedAt: Value(now),
      ));
      if (stamped == 0) {
        stale = true;
        return;
      }
      // Only now is the range queued: the bytes are this device's own, and
      // they go back out from the position the server and this device agreed
      // on — the position the answer was about.
      await (_db.update(_db.outbox)
            ..where((row) =>
                row.workspaceId.equals(workspaceId) &
                row.authorSeq.isBiggerOrEqualValue(from)))
          .write(OutboxCompanion(sentAt: const Value<DateTime?>(null)));
      // Flushes already in flight read the old queue; their acknowledgements
      // must not mark the rows re-queued here.
      _outboxQueueGeneration++;
    });
    if (stale) {
      throw StateError(
        'the accusation changed while the answer was being recorded',
      );
    }
  }

  /// Record the user's decision on an integrity alarm.
  ///
  /// The decision is written twice, in one transaction: on every refused change
  /// the accusation covers, and on the alarm itself. The refused rows are the
  /// durable history — never cleared, never deleted — and the alarm's row says
  /// what the answer is *now*. **Nothing is deleted and no envelope is
  /// touched**: refusing a change for good is a statement about it, not an
  /// erasure of it.
  ///
  /// [resolution] must be one the alarm's kind offers
  /// ([resolutionsOfferedForAlarmRow]). Anything else throws [StateError]
  /// without writing a row, and so does an alarm belonging to another
  /// Workspace — a client answers only for its own Workspace.
  ///
  /// A decision this build cannot carry out yet throws [UnsupportedError], also
  /// without writing. Which ones those are changes as the rest of #575 lands,
  /// so the error names the decision rather than failing quietly.
  ///
  /// **Taking upstream is the exception**: it has its own path
  /// ([_takeUpstream]), because it applies the held changes rather than only
  /// writing a decision about them. **Keeping ours on a rollback has one too**
  /// ([_keepOurs]), because its work is an upload rather than a note.
  Future<void> resolveAlarm(
    int alarmRowId,
    AlarmResolution resolution, {
    int? expectedOccurrenceCount,
  }) async {
    final alarm = await (_db.select(_db.integrityAlarms)
          ..where((row) => row.id.equals(alarmRowId)))
        .getSingleOrNull();
    if (alarm == null) {
      throw StateError('no integrity alarm with row id $alarmRowId');
    }
    if (alarm.workspaceId != workspaceId) {
      throw StateError(
        'integrity alarm $alarmRowId belongs to another Workspace',
      );
    }
    // The answer is about the accusation the User was shown. One raised again
    // since then — at another position, with more behind it — is a new
    // question, and nothing is queued or stamped for it.
    if (expectedOccurrenceCount != null &&
        alarm.occurrenceCount != expectedOccurrenceCount) {
      throw StateError(
        'the accusation changed after it was shown; ask again',
      );
    }
    final kind = integrityAlarmKindByCodeOrNull(alarm.kind);
    if (kind == null) {
      // A store written by a newer build can hold a code this one has never
      // heard of. It offers no decision, and asking about it is a mistake.
      throw StateError('an unknown alarm kind ${alarm.kind} offers no resolution');
    }
    if (!resolutionsOfferedForAlarmRow(alarm).contains(resolution)) {
      throw StateError(
        'a ${alarm.kind} alarm offers no ${resolution.code} resolution',
      );
    }
    switch (resolution) {
      case AlarmResolution.tookUpstream:
        // The one decision that relaxes a rule: the held changes are applied
        // without their chain position being verified.
        await _takeUpstream(alarm);
        return;
      case AlarmResolution.keptOurs:
        if (kind == IntegrityAlarmKind.ownWritesRollback) {
          // The one resolution whose work is an upload: this device's own
          // writes are marked unsent again, so the next flush re-posts them.
          await _keepOurs(alarm);
          return;
        }
        if (kind != IntegrityAlarmKind.ownWritesDivergence) {
          throw UnsupportedError(
            'keeping ours on a ${alarm.kind} alarm is not implemented yet (#575)',
          );
        }
        break;
      case AlarmResolution.rejectedPermanently:
        break;
    }
    final now = _now();
    await _db.transaction(() async {
      // The accusation must still be the one the User answered: a refusal that
      // arrived while they were answering is a new question, not this one.
      final current = await _alarmRow(alarm.id);
      if (current == null || current.occurrenceCount != alarm.occurrenceCount) {
        return;
      }
      // The snapshot is taken inside the transaction, so the rows it stamps and
      // the rows the settlement asks about are the same rows.
      final covered = await _rowsCoveredByAlarm(current, kind);
      for (final row in covered) {
        await (_db.update(_db.quarantinedOps)
              ..where((r) => r.id.equals(row.id)))
            .write(QuarantinedOpsCompanion(
          resolution: Value(resolution.code),
          resolutionDecidedAt: Value(now),
        ));
      }
      await _settleWhenNothingUndecided(
        alarm: current,
        kind: kind,
        resolution: resolution,
        now: now,
        forkHeadSeq: kind == IntegrityAlarmKind.authorChainFork &&
                current.authorMemberId != null
            ? await effectiveChainHeadSeq(current.authorMemberId!)
            : null,
      );
      if (kind == IntegrityAlarmKind.authorChainFork) {
        await _settleGapAlarmOf(current, resolution, now);
      }
    });
  }

  /// Record the user's decision on one refused change.
  ///
  /// A refusal that escalates to an alarm is settled on that alarm, not here —
  /// the alarm is what the screen shows and what the user answers. What arrives
  /// here is a refusal that stands on its own: a codec that will not read, a
  /// certificate that will not verify. The decision goes on the row, and the
  /// row is kept.
  ///
  /// The same rules as [resolveAlarm]: a decision the reason does not offer
  /// throws [StateError], another Workspace's row throws [StateError], and
  /// nothing is written either way.
  ///
  /// **A change the log has since applied is not offered a decision, and does
  /// not take one.** The refusal stamp is gone by then, so no later rebuild
  /// checks the decision: recording it would be recording a refusal of
  /// something that is already in, and the row would drop out of the screen
  /// saying the user had answered it. The same rule the rebuild follows when it
  /// admits a change the log had refused — an applied change has nothing left
  /// to decide ([_retireAdmittedRefusal]).
  ///
  /// The decision and the admission read each other's state inside one
  /// transaction, so the two are serialized: a decision recorded first keeps
  /// the change refused (the admission reads the decision, and skips the row),
  /// and an admission that lands first leaves the decision with nothing to
  /// decide (this method reads the admission, and refuses).
  Future<void> resolveRefusedItem(
    int quarantineRowId,
    AlarmResolution resolution,
  ) async {
    await _db.transaction(() async {
      final row = await (_db.select(_db.quarantinedOps)
            ..where((r) => r.id.equals(quarantineRowId)))
          .getSingleOrNull();
      if (row == null) {
        throw StateError('no refused change with row id $quarantineRowId');
      }
      if (row.workspaceId != workspaceId) {
        throw StateError(
          'refused change $quarantineRowId belongs to another Workspace',
        );
      }
      if (!resolutionsForRefusalCode(row.reason).contains(resolution)) {
        throw StateError(
          'a ${row.reason} refusal offers no ${resolution.code} resolution',
        );
      }
      if (await _refusalApplied(row)) {
        throw StateError(
          'refused change $quarantineRowId has been applied; there is nothing '
          'left to refuse',
        );
      }
      await (_db.update(_db.quarantinedOps)
            ..where((r) => r.id.equals(row.id)))
          .write(QuarantinedOpsCompanion(
        resolution: Value(resolution.code),
        resolutionDecidedAt: Value(_now()),
      ));
    });
  }

  /// Whether the change a refused row holds has since been applied.
  ///
  /// The bytes are compared, not just the transport `seq`: a server that hands
  /// the same `seq` out twice leaves two ops at one position, and a decision
  /// about one of them is not a decision about the other.
  Future<bool> _refusalApplied(QuarantineRow row) async {
    final seq = row.seq;
    if (seq == null) return false;
    final op = await _opLogRowAt(seq);
    if (op == null || op.appliedAt == null) return false;
    return sameBytes(op.envelope, row.envelope);
  }

  /// The refused changes an alarm covers.
  ///
  /// **Same Workspace, same author, unreleased, undecided, and refusing for
  /// this kind of reason** — the escalation the accusation was raised for. A
  /// row the user has already answered is not covered again, and a released row
  /// is out of it entirely: it was re-admitted, so there is nothing left to
  /// decide about it.
  ///
  /// A fork is the one kind with no reason of its own. Its rows are the
  /// author's gap rows at or below the effective chain head — the continuations
  /// that lost their position — because a fork is not a refusal but the choice
  /// between two of them.
  Future<List<QuarantineRow>> _rowsCoveredByAlarm(
    IntegrityAlarmRow alarm,
    IntegrityAlarmKind kind,
  ) async {
    final forkHeadSeq = kind == IntegrityAlarmKind.authorChainFork &&
            alarm.authorMemberId != null
        ? await effectiveChainHeadSeq(alarm.authorMemberId!)
        : null;
    final forkClaimSeq = kind == IntegrityAlarmKind.authorChainFork
        ? await _forkClaimSeq(alarm)
        : null;
    return (_db.select(_db.quarantinedOps)
          ..where((t) => _coveredRows(
                t,
                kind: kind,
                authorMemberId: alarm.authorMemberId,
                forkHeadSeq: forkHeadSeq,
                forkClaimSeq: forkClaimSeq,
                namedRowId: alarm.quarantineOpRowId,
              ))
          ..orderBy([(row) => OrderingTerm(expression: row.id)]))
        .get();
  }

  /// The author's chain position the accused claimant holds.
  ///
  /// A fork is proven one position at a time: the release scan finds every
  /// claimant at head + 1 and shows that none of them chains to the head. Two
  /// envelopes can claim that one position, and both are then proven against
  /// the same head — so the answer covers both, not only the one the
  /// accusation happens to name.
  Future<int?> _forkClaimSeq(IntegrityAlarmRow alarm) async {
    final namedRowId = alarm.quarantineOpRowId;
    if (namedRowId == null) return null;
    final row = await (_db.select(_db.quarantinedOps)
          ..where((row) => row.id.equals(namedRowId)))
        .getSingleOrNull();
    return row?.authorSeq;
  }

  /// The refused changes an accusation covers, as one predicate.
  ///
  /// **Same Workspace, same author, unreleased, undecided, and refusing for
  /// this kind of reason** — the escalation the accusation was raised for. A
  /// row the user has already answered is not covered again, and a released row
  /// is out of it entirely: it was re-admitted, so there is nothing left to
  /// decide about it.
  ///
  /// A fork is the one kind with no reason of its own. Its rows are the
  /// author's gap rows at or below the effective chain head — the continuations
  /// that lost their position — because a fork is not a refusal but the choice
  /// between two of them.
  ///
  /// **One definition, two questions.** The snapshot asks it for the rows to
  /// stamp; the settlement asks it for the rows still undecided. Both must
  /// mean the same thing, or the settlement can close an accusation over a
  /// refusal it never covered.
  Expression<bool> _coveredRows(
    $QuarantinedOpsTable table, {
    required IntegrityAlarmKind kind,
    required String? authorMemberId,
    int? forkHeadSeq,
    int? forkClaimSeq,
    int? namedRowId,
  }) {
    final sameAuthor = authorMemberId == null
        ? table.authorMemberId.isNull()
        : table.authorMemberId.equals(authorMemberId);
    final unanswered = table.releasedAt.isNull() & table.resolution.isNull();
    if (kind == IntegrityAlarmKind.authorChainFork) {
      // A fork is not a refusal but the choice between two continuations: the
      // author's gap rows at or below the effective chain head.
      if (forkHeadSeq == null) return const Constant(false);
      // **And the position the accused claimant holds.** The release scan
      // proves a mismatch at head + 1 and does not advance the head, so the
      // claimant it accused sits *above* the head — outside the range above.
      // Leaving it out would let a rejection close the fork while the gap the
      // fork holds open stays undecided, and the User would be asked about a
      // gap they had already answered.
      final withinHead = table.authorSeq.isSmallerOrEqualValue(forkHeadSeq);
      // **Every claimant at that position**, not only the one the accusation
      // names: the alarm is keyed by `(workspace, kind, author)` and keeps the
      // first row it saw, so the row it names is one of several proven
      // mismatches. Naming one of them and answering only that one would
      // settle the fork over a mismatch that is still undecided, and leave the
      // rest of the position a question nobody was asked. A gap at another
      // position is a gap of its own, and stays out of it.
      final atClaimedPosition = forkClaimSeq == null
          ? const Constant(false)
          : table.authorSeq.equals(forkClaimSeq);
      final named = namedRowId == null
          ? const Constant(false)
          : table.id.equals(namedRowId);
      return table.workspaceId.equals(workspaceId) &
          unanswered &
          sameAuthor &
          table.reason.equals(SyncRejectionReason.authorChainGap.code) &
          (withinHead | atClaimedPosition | named);
    }
    final reasons = _reasonCodesEscalatingTo(kind);
    if (reasons.isEmpty) return const Constant(false);
    return table.workspaceId.equals(workspaceId) &
        unanswered &
        sameAuthor &
        table.reason.isIn(reasons);
  }

  /// The held changes a take upstream is about.
  ///
  /// Two sets, and the second one is the work a decision left behind:
  ///
  /// * the author's gap rows that are **still held and still undecided** — the
  ///   work the decision is about; and
  /// * the rows already decided as *taken upstream* whose **projection has not
  ///   reached the domain store yet** — the work of a take upstream that did
  ///   not finish. The decision was recorded on them, and the change is done
  ///   again so the projection sees it: a take upstream that is answered twice
  ///   must reach the domain store both times.
  ///
  /// The second set deliberately ignores [QuarantinedOps.releasedAt]. A chain
  /// release re-admits the row and the change goes into the log, but it does
  /// not put the change on the User's screen — so a released row whose
  /// projection never succeeded is still work, and excluding it would let a
  /// retry answer the accusation over work it never did.
  Expression<bool> _takenUpstreamRows(
    $QuarantinedOpsTable table, {
    required String? authorMemberId,
  }) {
    final sameAuthor = authorMemberId == null
        ? table.authorMemberId.isNull()
        : table.authorMemberId.equals(authorMemberId);
    final reasons = _reasonCodesEscalatingTo(IntegrityAlarmKind.authorChainGap);
    return table.workspaceId.equals(workspaceId) &
        sameAuthor &
        table.reason.isIn(reasons) &
        ((table.releasedAt.isNull() & table.resolution.isNull()) |
            (table.resolution.equals(AlarmResolution.tookUpstream.code) &
                table.resolutionProjectedAt.isNull()));
  }

  /// The refusal reasons that escalate to this kind of accusation.
  ///
  /// An unknown reason code escalates to nothing: it cannot name a kind, and a
  /// store written by a newer build must not make a decision cover a row this
  /// build cannot classify.
  static List<String> _reasonCodesEscalatingTo(IntegrityAlarmKind kind) => [
        for (final reason in SyncRejectionReason.values)
          if (alarmForRejection(reason) == kind) reason.code,
      ];

  /// No refused change the accusation covers is still undecided.
  Expression<bool> _noUndecidedCoveredRow({
    required IntegrityAlarmKind kind,
    required String? authorMemberId,
    int? forkHeadSeq,
    int? forkClaimSeq,
    int? namedRowId,
  }) =>
      notExistsQuery(
        _db.select(_db.quarantinedOps)
          ..where((t) => _coveredRows(
                t,
                kind: kind,
                authorMemberId: authorMemberId,
                forkHeadSeq: forkHeadSeq,
                forkClaimSeq: forkClaimSeq,
                namedRowId: namedRowId,
              )),
      );

  /// Settle an accusation, if it is still the accusation that was answered and
  /// nothing it covers is left undecided.
  ///
  /// **The check and the write are one statement.** A refusal that arrives
  /// while the answer is being recorded is not covered by that answer: the
  /// check sees it and the accusation stands, or the refusal's own re-raise
  /// re-opens it. Either way the accusation is not closed over something the
  /// User was never shown.
  ///
  /// The occurrence count is the other half of the same guard: a re-raise
  /// behind the answer's back means the accusation has grown since the User
  /// was asked, and their answer was about the smaller one.
  Future<void> _settleWhenNothingUndecided({
    required IntegrityAlarmRow alarm,
    required IntegrityAlarmKind kind,
    required AlarmResolution resolution,
    required DateTime now,
    int? forkHeadSeq,
  }) async {
    // The position the accused claimant holds, read here so the settlement
    // asks about exactly the rows the snapshot stamped — one definition, two
    // questions.
    final forkClaimSeq = kind == IntegrityAlarmKind.authorChainFork
        ? await _forkClaimSeq(alarm)
        : null;
    await (_db.update(_db.integrityAlarms)
          ..where((row) =>
              row.id.equals(alarm.id) &
              row.resolvedAt.isNull() &
              row.occurrenceCount.equals(alarm.occurrenceCount) &
              _noUndecidedCoveredRow(
                kind: kind,
                authorMemberId: alarm.authorMemberId,
                forkHeadSeq: forkHeadSeq,
                forkClaimSeq: forkClaimSeq,
                namedRowId: alarm.quarantineOpRowId,
              )))
        .write(IntegrityAlarmsCompanion(
      resolution: Value(resolution.code),
      resolutionDecidedAt: Value(now),
      resolvedAt: Value(now),
    ));
  }

  /// The accusation with this row id, if it is still there.
  Future<IntegrityAlarmRow?> _alarmRow(int id) =>
      (_db.select(_db.integrityAlarms)..where((row) => row.id.equals(id)))
          .getSingleOrNull();

  /// The standing accusation of this kind against this author, if there is one.
  Future<IntegrityAlarmRow?> _standingAlarm(
    IntegrityAlarmKind kind,
    String? authorMemberId,
  ) =>
      (_db.select(_db.integrityAlarms)
            ..where((row) =>
                row.workspaceId.equals(workspaceId) &
                row.kind.equals(kind.code) &
                row.resolvedAt.isNull() &
                (authorMemberId == null
                    ? row.authorMemberId.isNull()
                    : row.authorMemberId.equals(authorMemberId))))
          .getSingleOrNull();

  /// Settle the author's gap alarm with a fork's decision, once no unreleased,
  /// undecided gap row is left for that author.
  ///
  /// The gap alarm stands because a refused change of that author is still
  /// waiting; once the fork's decision has stamped every one of those rows the
  /// wait is over, and the alarm goes with it. **Undecided** is what counts: a
  /// row the user has already answered is not a reason to keep asking.
  ///
  /// Only a standing alarm is stamped. One that no longer stands has nothing
  /// left to settle, and a decision written on it would be a claim about an
  /// accusation that has already been answered by the world.
  Future<void> _settleGapAlarmOf(
    IntegrityAlarmRow fork,
    AlarmResolution resolution,
    DateTime now,
  ) async {
    final author = fork.authorMemberId;
    if (author == null) return;
    final gap = await _standingAlarm(IntegrityAlarmKind.authorChainGap, author);
    if (gap == null) return;
    // A row taken upstream that has not reached the domain store is still
    // work: rejecting the fork does not answer it.
    if (await _hasUnprojectedTakeUpstream(author)) return;
    await _settleWhenNothingUndecided(
      alarm: gap,
      kind: IntegrityAlarmKind.authorChainGap,
      resolution: resolution,
      now: now,
    );
  }

  Future<int> _cursor() async {
    final row = await (_db.select(_db.syncCursors)
          ..where((r) => r.workspaceId.equals(workspaceId)))
        .getSingleOrNull();
    return row?.lastSeq ?? 0;
  }

  /// Record that a rebuild from the op log is owed, on this Workspace's cursor
  /// row. Touches only the marker, never the cursor.
  Future<void> _requireRebuild() async {
    await _db.into(_db.syncCursors).insert(
          SyncCursorsCompanion.insert(
            workspaceId: workspaceId,
            lastSeq: 0,
            rebuildRequiredAt: Value(_now()),
          ),
          onConflict: DoUpdate(
            (_) => SyncCursorsCompanion(rebuildRequiredAt: Value(_now())),
          ),
        );
  }

  /// When a rebuild became owed, or null when none is.
  Future<DateTime?> _rebuildRequiredSince() async {
    final row = await (_db.select(_db.syncCursors)
          ..where((r) => r.workspaceId.equals(workspaceId)))
        .getSingleOrNull();
    return row?.rebuildRequiredAt;
  }

  /// Clear the marker [raisedAt] read before the rebuild. The equality guard
  /// leaves a marker raised again while the rebuild ran. Drift keeps a
  /// `DateTime` as ISO-8601 text, so the column keeps milliseconds: two raises
  /// inside the same millisecond are not told apart, and nothing raises the
  /// marker during a rebuild today.
  Future<void> _clearRebuildRequirement(DateTime raisedAt) async {
    await (_db.update(_db.syncCursors)
          ..where((r) =>
              r.workspaceId.equals(workspaceId) &
              r.rebuildRequiredAt.equals(raisedAt)))
        .write(const SyncCursorsCompanion(rebuildRequiredAt: Value(null)));
  }

  Future<void> _saveCursor(int seq) async {
    await _db.into(_db.syncCursors).insertOnConflictUpdate(
          SyncCursorsCompanion.insert(workspaceId: workspaceId, lastSeq: seq),
        );
  }

  /// Rewind the pull cursor so the next [pull] replays the whole log.
  ///
  /// Replay is not a special mode: a bootstrap *is* a pull from zero, and an
  /// already-populated device replaying is how the idempotence of reduction is
  /// checked. Nothing is cleared — re-applying an op whose HLC equals the
  /// stored one is a no-op, and tombstones cannot un-tombstone.
  Future<void> resetCursorForReplay() async {
    await (_db.update(_db.syncCursors)
          ..where((row) => row.workspaceId.equals(workspaceId)))
        .write(const SyncCursorsCompanion(lastSeq: Value(0)));
  }

  /// Stamped on pull completion, independent of flush state (see [SyncHealth]).
  Future<void> _stampPullCompleted() async {
    await _db.into(_db.syncCursors).insertOnConflictUpdate(
          SyncCursorsCompanion.insert(
            workspaceId: workspaceId,
            lastSeq: await _cursor(),
            lastSyncCompletedAt: Value(_now()),
          ),
        );
  }

  // --- Health ----------------------------------------------------------------

  /// SQL behind both [health] and [watchSyncHealth], so the one-shot and the
  /// stream cannot report different numbers.
  ///
  /// The two counts that ask the User for something — `actionable_alarm_count`
  /// and `reportable_quarantine_count` — also skip the rows the User has
  /// already answered (`resolution IS NULL`). A decided condition is still
  /// *unresolved*: it happened, and the User should still be told it happened.
  /// It is just no longer something to be asked about, so it does not drive
  /// the indicator. `unresolved_alarm_count` and `quarantine_count` keep
  /// counting every row.
  ///
  /// The two class-filtered counts inline their code lists rather than binding
  /// them, and the lists are **generated from the classification itself**
  /// (`sync_condition_class.dart`) rather than written out here: a hand-written
  /// `IN (…)` beside an enum is a second copy of the decision, free to drift the
  /// first time a kind is added. The interpolated values are our own enum codes,
  /// never anything a server or a user supplied.
  static final String _healthSql = '''
SELECT
  (SELECT COUNT(*) FROM outbox
    WHERE workspace_id = ? AND sent_at IS NULL) AS pending_op_count,
  (SELECT COUNT(*) FROM quarantined_ops
    WHERE workspace_id = ? AND released_at IS NULL) AS quarantine_count,
  (SELECT COUNT(*) FROM quarantined_ops
    WHERE workspace_id = ? AND released_at IS NULL
      AND reason NOT IN (${_sqlCodeList(transientRefusalCodes)})
      AND resolution IS NULL)
    AS reportable_quarantine_count,
  (SELECT COUNT(*) FROM integrity_alarms
    WHERE workspace_id = ? AND resolved_at IS NULL) AS unresolved_alarm_count,
  (SELECT COUNT(*) FROM integrity_alarms
    WHERE workspace_id = ? AND resolved_at IS NULL
      AND kind IN (${_sqlCodeList(actionableAlarmCodes)})
      AND resolution IS NULL)
    AS actionable_alarm_count,
  (SELECT group_concat(DISTINCT kind) FROM integrity_alarms
    WHERE workspace_id = ? AND resolved_at IS NULL) AS alarm_kinds,
  (SELECT last_sync_completed_at FROM sync_cursors
    WHERE workspace_id = ?) AS last_synced_at
''';

  /// Enum codes as a SQL literal list. They are `[a-z_]` identifiers declared in
  /// this repo's own source; the assertion says so out loud rather than trusting
  /// a reader to check.
  static String _sqlCodeList(List<String> codes) {
    assert(
      codes.every((code) => RegExp(r'^[a-z0-9_]+$').hasMatch(code)),
      'a condition code that is not a bare identifier cannot be inlined',
    );
    // An empty class would inline as `IN ()` / `NOT IN ()`, which SQLite rejects
    // outright — and there is no literal that is right for both callers, since
    // an empty class means "match nothing" under `IN` and "match everything"
    // under `NOT IN`. It cannot happen: both lists are derived from exhaustive
    // switches over non-empty enums. Say so at the point of construction rather
    // than let the health query fail later as a syntax error, or — worse — hand
    // one of the two callers a silently wrong count.
    if (codes.isEmpty) {
      throw StateError('a condition class with no codes cannot be inlined');
    }
    return codes.map((code) => "'$code'").join(', ');
  }

  Selectable<QueryRow> _healthQuery() => _db.customSelect(
        _healthSql,
        variables: [
          Variable<String>(workspaceId),
          Variable<String>(workspaceId),
          Variable<String>(workspaceId),
          Variable<String>(workspaceId),
          Variable<String>(workspaceId),
          Variable<String>(workspaceId),
          Variable<String>(workspaceId),
        ],
        readsFrom: {
          _db.outbox,
          _db.quarantinedOps,
          _db.integrityAlarms,
          _db.syncCursors,
        },
      );

  static SyncHealth _readHealth(QueryRow row) {
    final kinds = row.read<String?>('alarm_kinds');
    return SyncHealth(
      pendingOpCount: row.read<int>('pending_op_count'),
      quarantineCount: row.read<int>('quarantine_count'),
      reportableQuarantineCount: row.read<int>('reportable_quarantine_count'),
      unresolvedAlarmCount: row.read<int>('unresolved_alarm_count'),
      actionableAlarmCount: row.read<int>('actionable_alarm_count'),
      alarmKinds: kinds == null || kinds.isEmpty ? const <String>{} : kinds.split(',').toSet(),
      lastSyncedAt: row.read<DateTime?>('last_synced_at'),
    );
  }

  Future<SyncHealth> health() async => _readHealth(await _healthQuery().getSingle());

  Stream<SyncHealth> watchSyncHealth() =>
      _healthQuery().watchSingle().map(_readHealth);

  // --- Quarantine and alarm surface ------------------------------------------

  /// Every refused envelope this device holds, oldest first.
  ///
  /// Released rows are included by default: a reorder that healed is still
  /// something the user gets to look at, and hiding it would make the
  /// distinction between "healed" and "never happened" invisible.
  Future<List<QuarantineRow>> quarantined({bool includeReleased = true}) =>
      _quarantineQuery(includeReleased: includeReleased).get();

  /// The same rows, live — what the sync-health screen renders.
  ///
  /// The sibling of [watchIntegrityAlarms], and released rows are included for
  /// the same reason [quarantined] includes them: a reorder that healed is what
  /// separates "withheld and still missing" from "arrived out of order", and the
  /// screen marks it re-admitted rather than hiding it.
  Stream<List<QuarantineRow>> watchQuarantined() => _quarantineQuery().watch();

  Selectable<QuarantineRow> _quarantineQuery({bool includeReleased = true}) =>
      _db.select(_db.quarantinedOps)
        ..where((row) => includeReleased
            ? row.workspaceId.equals(workspaceId)
            : row.workspaceId.equals(workspaceId) & row.releasedAt.isNull())
        ..orderBy([(row) => OrderingTerm(expression: row.id)]);

  /// The refused rows whose change the log has since applied.
  ///
  /// A refusal the log has since applied has nothing left to decide — the
  /// change is in, the refusal stamp is gone, and no later rebuild checks a
  /// decision about it (see [resolveRefusedItem]). The row stays: it is the
  /// evidence that the change arrived out of order. What goes is the offer.
  ///
  /// The join is on the transport `seq`, which a server that hands the same
  /// `seq` out twice repeats, and the bytes are compared here rather than in
  /// the query: one op's application is never read as another's.
  Stream<Set<int>> watchAppliedRefusalRowIds() {
    final query = _db.select(_db.quarantinedOps).join([
      innerJoin(
        _db.opLog,
        _db.opLog.seq.equalsExp(_db.quarantinedOps.seq) &
            _db.opLog.workspaceId.equalsExp(_db.quarantinedOps.workspaceId),
      ),
    ])
      ..where(_db.quarantinedOps.workspaceId.equals(workspaceId) &
          _db.opLog.appliedAt.isNotNull());
    return query.watch().map((rows) {
      final ids = <int>{};
      for (final row in rows) {
        final refusal = row.readTable(_db.quarantinedOps);
        final op = row.readTable(_db.opLog);
        if (sameBytes(refusal.envelope, op.envelope)) ids.add(refusal.id);
      }
      return ids;
    });
  }

  /// Watchable so the UI can surface "something arrived that we refused" rather
  /// than swallowing it. Counts what still stands refused.
  Stream<int> watchQuarantineCount() => (_db.selectOnly(_db.quarantinedOps)
        ..addColumns([_db.quarantinedOps.id.count()])
        ..where(_db.quarantinedOps.workspaceId.equals(workspaceId) &
            _db.quarantinedOps.releasedAt.isNull()))
      .map((row) => row.read(_db.quarantinedOps.id.count()) ?? 0)
      .watchSingle();

  /// Every accusation this device has recorded, oldest first — including
  /// resolved ones, which are the record that a reorder healed rather than a
  /// drop having never happened.
  Future<List<IntegrityAlarmRow>> integrityAlarms() => _alarmQuery().get();

  /// The surfacing seam #553's sync indicator consumes. This slice ships the
  /// stream and no widget.
  Stream<List<IntegrityAlarmRow>> watchIntegrityAlarms() => _alarmQuery().watch();

  Selectable<IntegrityAlarmRow> _alarmQuery() => _db.select(_db.integrityAlarms)
    ..where((row) => row.workspaceId.equals(workspaceId))
    ..orderBy([(row) => OrderingTerm(expression: row.id)]);

  /// Every envelope this device authored, in author order — the replay source
  /// for the idempotency test and #551's chain-verification substrate.
  Future<List<Uint8List>> authoredEnvelopes() async {
    final rows = await (_db.select(_db.outbox)
          ..where((row) => row.workspaceId.equals(workspaceId))
          ..orderBy([(row) => OrderingTerm(expression: row.authorSeq)]))
        .get();
    return [for (final row in rows) row.envelope];
  }
}

String _hex(Uint8List bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
