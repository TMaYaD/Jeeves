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
/// client cannot have.
library;

import 'dart:math' show Random, max, min;

import 'package:drift/drift.dart';
// The append to `op_log` is a plain insert whose uniqueness constraints are the
// authority on a taken slot (see [SyncClient._logReceived]), so this file has to
// be able to tell that one failure apart from every other database failure.
// `common.dart` is the platform-neutral half of the package: the exception type
// and the result codes, no FFI.
import 'package:sqlite3/common.dart' show SqlExtendedError, SqliteException;
import 'package:uuid/uuid.dart';

import 'chain_verifier.dart';
import 'control_payload.dart';
import 'domain_projector.dart';
import 'domain_reconciler.dart';
import 'envelope.dart';
import 'grants_view.dart';
import 'hlc.dart';
import 'ids.dart';
import 'key_wraps.dart';
import 'member_identity.dart';
import 'op_payload.dart';
import 'prune_payload.dart';
import 'reducer.dart';
import 'recovery_escrow.dart';
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
        _reducer = reducer,
        _transport = transport,
        directory = directory ?? MemberDirectory(),
        workspaceKeys = workspaceKeys ?? InMemoryWorkspaceKeyStore(),
        _now = now ?? DateTime.now {
    this.directory.rememberSelf(identity);
  }

  final String workspaceId;

  /// The owning User. Half of the escrow slot key, and not otherwise trusted.
  final String userId;

  /// Whether this client speaks for the User-global preferences Workspace.
  ///
  /// The one place a Workspace's *identity* changes a rule: preferences grant
  /// every Device and no Service ever, and the boundary is structural rather than
  /// a policy the reducer could be talked out of.
  bool get isPreferencesWorkspace => workspaceId == userPreferencesWorkspaceId(userId);
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

  /// Set when a control fork resolution invalidated the authorization verdicts
  /// content ops were applied under.
  ///
  /// Acted on at the end of the pull rather than mid-page: a rebuild replays the
  /// whole retained log, so doing it per-op inside a page would be quadratic in
  /// the page for no extra correctness.
  bool _rebuildRequired = false;

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
  }) async {
    final payload = OpPayload(
      collection: collection,
      entityId: entityId,
      hlc: _clock.send(),
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
  /// [_dropSupersededGenesis].
  /// The queue is posted in [maxOpsPerBatch] chunks, in `author_seq` order, each
  /// acknowledged before the next goes out. Unchunked, a device that authored
  /// more than the server's cap while offline would re-POST the same oversized
  /// batch on every `sync()`, be refused 413 `batch_too_large` every time, and
  /// never drain — a permanent outage in exactly the offline case the outbox is
  /// for. Chunking in chain order is what keeps the server seeing this author's
  /// positions in the order they were authored.
  Future<FlushOutcome> flushOutbox() async {
    final pending = await (_db.select(_db.outbox)
          ..where((row) => row.workspaceId.equals(workspaceId) & row.sentAt.isNull())
          ..orderBy([(row) => OrderingTerm(expression: row.authorSeq)]))
        .get();
    if (pending.isEmpty) return FlushOutcome.flushed;

    for (var start = 0; start < pending.length; start += maxOpsPerBatch) {
      final chunk = pending.sublist(
        start,
        min(start + maxOpsPerBatch, pending.length),
      );
      try {
        // A duplicate result is still an acknowledgement: the server holds the op.
        await transport.postOps(workspaceId, [for (final row in chunk) row.envelope]);
      } on AuthorChainConflictException catch (conflict) {
        await _recordOwnWritesVerdict(conflict);
        return FlushOutcome.retained;
      } on SyncTransportException catch (refusal) {
        if (refusal.code != genesisNotFirstCode) rethrow;
        // Genesis sits at the head of the queue, so everything still unsent is
        // queued behind it and goes with it — not just this chunk.
        await _dropSupersededGenesis(pending.sublist(start));
        return FlushOutcome.genesisSuperseded;
      }
      await _markSent(chunk);
    }
    return FlushOutcome.flushed;
  }

  /// Stamp one acknowledged chunk in a single UPDATE.
  Future<void> _markSent(List<OutboxRow> acknowledged) =>
      (_db.update(_db.outbox)
            ..where((row) => row.id.isIn([for (final row in acknowledged) row.id])))
          .write(OutboxCompanion(sentAt: Value(_now())));

  /// Discard a genesis the race is already lost, and everything queued behind it.
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
  Future<void> _dropSupersededGenesis(List<OutboxRow> superseded) async {
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

  /// The own-writes verdict on one refused POST.
  ///
  /// The client cannot distinguish a server that rolled our writes back from a
  /// device restored off an older local backup, so the detail names both. The
  /// response is identical either way — retain the outbox, re-number nothing —
  /// and un-wedging is an operator action that needs the user in the loop.
  Future<void> _recordOwnWritesVerdict(AuthorChainConflictException conflict) async {
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
  Future<void> pull() async {
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
    // A rotation landed, or something is still waiting on a wrap. Either way the
    // fetch is bounded — one round-trip per pull, never one per op — and the
    // freshness race F14b names (the wraps PUT landing moments after the rotate op)
    // resolves on the next pull rather than as a mystery decryption failure.
    if (_epochKeyRefreshRequired || await _hasOpsAwaitingEpochKeys()) {
      final learnedEpochKeys = await refreshEpochKeys();
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
      if (learnedEpochKeys > 0) {
        // A rebuild skips rows it cannot decode, and those rows are in `op_log`
        // rather than the quarantine — the release scan above will never reach
        // them. A newly arrived epoch key is the one event that can change that
        // verdict, so it re-arms the replay. Gated on *learning* rather than on
        // the skip, because an unconditional re-arm would replay the whole log on
        // every pull for as long as a key stayed missing, and a key is learned at
        // most once per epoch.
        _rebuildRequired = true;
      }
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
    if (_rebuildRequired) {
      // A control fork resolved during this pull, so the authorization verdicts
      // the content ops applied under are no longer the right ones.
      affected.addAll(await rebuildFromOpLog());
    }
    // Projection is the tail of the receive order, one pass per batch: an
    // entity touched by three ops in one pull is projected once, from the
    // reduced state all three produced.
    final touched = await projector?.project(affected);
    // And the convergence passes run on what it changed. This is the route by
    // which a peer's Tag entity first reaches the domain store, so it is where a
    // duplicate `(name, type)` group is folded and a junction stranded on a
    // tombstoned tag is rehomed. Outside any transaction, before the completion
    // stamp, and never on the author path — see [DomainReconciler.reconcile].
    if (touched != null) await reconciler?.reconcile(touched);
    await _stampPullCompleted();
  }

  /// Clear derived state and replay the retained log, recomputing **only** the
  /// authorization verdict.
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
  /// **Entities the rebuild *un*-reduces are surfaced too**, which is the whole
  /// reason [_reducedEntities] is read before the wipe. An entity whose every op
  /// became refused reduces to nothing, so the replay never names it — and a
  /// projector told only about what re-applied would leave its domain row
  /// standing as the last visible trace of a quarantined branch. The pre-wipe set
  /// is unioned into the return value, so such an entity reaches
  /// [DomainProjector.project] with no live field and is deleted there.
  Future<Set<AffectedEntity>> rebuildFromOpLog() async {
    _rebuildRequired = false;
    final rows = await (_db.select(_db.opLog)
          ..where((row) => row.workspaceId.equals(workspaceId))
          ..orderBy([(row) => OrderingTerm(expression: row.seq)]))
        .get();

    // Read before the wipe: after it there is no way to tell an entity that
    // reduced to nothing from one this device never held.
    final reducedBefore = await _reducedEntities();

    // Derived state only. The op log, the outbox, the applied control log and the
    // quarantine are all evidence, and evidence is not edited.
    await _db.transaction(() async {
      await _db.delete(_db.reducedFields).go();
      await _db.delete(_db.fieldClocks).go();
      await _db.delete(_db.rowTombstones).go();
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

      final authorization = view.verdictFor(
        authorMemberId: header.authorMemberId,
        opClass: header.opClass,
        seq: row.seq,
      );
      if (authorization != null) {
        await _stampRefused(row.seq, authorization.reason);
        continue;
      }
      try {
        affected.addAll(await _reducer.apply(
          payload,
          authorMemberIdHex: memberIdToHex(header.authorMemberId),
        ));
        // Newly authorized by the corrected view: clear the stale refusal so the
        // row stops claiming a verdict that no longer stands.
        if (refused != null) await _clearRefused(row.seq);
        await _stampApplied(row.seq);
      } on SyncRejection catch (rejection) {
        // A guard that fires on a *fresh* evaluation is recorded as it was the
        // first time; the clock is not re-consulted for anything already judged.
        await _stampRefused(row.seq, rejection.reason);
      }
    }
    // Everything that *was* reduced, whether or not it reduced again: an entity
    // whose ops all became refused is exactly the case the projector has to hear
    // about, and it is the one the replay above can never name.
    return affected..addAll(reducedBefore);
  }

  /// Every entity the reduced substrate currently holds any trace of — see the
  /// top-level [reducedEntities], which the first-open domain rebuild shares.
  Future<Set<AffectedEntity>> _reducedEntities() => reducedEntities(_db);

  Future<void> _clearRefused(int seq) async {
    await (_db.update(_db.opLog)
          ..where((row) => row.workspaceId.equals(workspaceId) & row.seq.equals(seq)))
        .write(const OpLogCompanion(refusedReason: Value(null)));
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
  Future<Set<AffectedEntity>> _receive(PulledOp pulled) async {
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
          if (!await _logReceived(pulled, controlHeader)) return false;
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

      if (!await _logReceived(pulled, header)) return const {};

      // The authorization stage, between the chain verdict and the reducer
      // guards. Evaluated at the op's *own* server seq, never against current
      // control state — see [GrantsView]. A refusal here is #551's
      // logged-but-refused class: the row above is already written and advances
      // per-author accounting, so an honest successor is never falsely gapped.
      final authorization = (await grantsView()).verdictFor(
        authorMemberId: header.authorMemberId,
        opClass: header.opClass,
        seq: pulled.seq,
      );
      if (authorization != null) {
        await _stampRefused(pulled.seq, authorization.reason);
        await _refuse(pulled, authorization, header);
        // The chain head advanced, so a quarantined successor may now be valid.
        return _releaseChainSuccessors(header.authorMemberId);
      }

      final affected = <AffectedEntity>{};
      try {
        affected.addAll(await _reducer.apply(
          payload,
          authorMemberIdHex: memberIdToHex(header.authorMemberId),
        ));
        _clock.receive(payload.hlc);
        await _stampApplied(pulled.seq);
      } on SyncRejection catch (rejection) {
        // Logged-but-refused: the envelope is chain evidence and stays, the
        // payload never applies, and the row records which guard fired. Handled
        // here rather than by the outer catch so the release scan below still
        // runs — the head advanced, so a quarantined successor may now be valid.
        await _stampRefused(pulled.seq, rejection.reason);
        await _refuse(pulled, rejection, header);
      }
      affected.addAll(await _releaseChainSuccessors(header.authorMemberId));
      return affected;
    } on SyncRejection catch (rejection) {
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
      if (!await _hasUnreleasedGap(author)) {
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
        if (!await _hasUnreleasedGap(authorMemberId)) {
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
        'control op at seq ${pulled.seq} lost the fork tie-break for '
        'prev_control_hash ${_hex(payload.prevControlHash)}',
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
    // convergence of the grants view alone is not convergence.
    _rebuildRequired = true;
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
  /// Acted on at the end of the pull rather than mid-page, for [_rebuildRequired]'s
  /// reason: a rotate and the first op at the new epoch usually arrive in one page,
  /// and re-fetching per op would spend a round-trip per op.
  bool _epochKeyRefreshRequired = false;

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
        await workspaceKeys.remember(
          workspaceId,
          record.epoch,
          await unwrapEpochKeyForMember(
            wrap: record.wrap,
            kexKeyPair: identity.kexKeyPair,
            workspaceId: workspaceId,
            epoch: record.epoch,
            memberId: identity.memberId,
            kexKeyId: ownKexKeyId,
          ),
        );
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
  Future<void> _refuse(
    PulledOp pulled,
    SyncRejection rejection,
    OpHeader? header, {
    ({IntegrityAlarmKind kind, String detail})? servingAccusation,
  }) async {
    final quarantineRowId = await _quarantine(pulled, rejection, header);
    final accusations = <IntegrityAlarmKind, String>{};
    if (servingAccusation != null) {
      accusations[servingAccusation.kind] = servingAccusation.detail;
    }
    final escalated = alarmForRejection(rejection.reason);
    if (escalated != null) accusations.putIfAbsent(escalated, () => rejection.message);
    for (final accusation in accusations.entries) {
      await _raiseAlarm(
        accusation.key,
        authorMemberId: header?.authorMemberId,
        detail: accusation.value,
        quarantineOpRowId: quarantineRowId,
      );
    }
  }

  /// Record one refused envelope, or bump the accusation it already produced.
  ///
  /// Dedupe lives here rather than in one caller so it is a property of every
  /// quarantine path: a server re-serving the same refused bytes on every sync
  /// raises the alarm's occurrence count instead of growing the table without
  /// bound. Returns the row the refusal is filed under.
  Future<int> _quarantine(
    PulledOp pulled,
    SyncRejection rejection,
    OpHeader? header,
  ) async {
    final existing = await (_db.select(_db.quarantinedOps)
          ..where((row) =>
              row.workspaceId.equals(workspaceId) &
              row.seq.equals(pulled.seq) &
              row.reason.equals(rejection.reason.code) &
              row.releasedAt.isNull()))
        .get();
    for (final row in existing) {
      if (sameBytes(row.envelope, pulled.envelope)) return row.id;
    }
    return _db.into(_db.quarantinedOps).insert(
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
  Future<int> _raiseAlarm(
    IntegrityAlarmKind kind, {
    required String detail,
    String? authorMemberId,
    int? quarantineOpRowId,
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

  Future<int> _cursor() async {
    final row = await (_db.select(_db.syncCursors)
          ..where((r) => r.workspaceId.equals(workspaceId)))
        .getSingleOrNull();
    return row?.lastSeq ?? 0;
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
  static const String _healthSql = '''
SELECT
  (SELECT COUNT(*) FROM outbox
    WHERE workspace_id = ? AND sent_at IS NULL) AS pending_op_count,
  (SELECT COUNT(*) FROM quarantined_ops
    WHERE workspace_id = ? AND released_at IS NULL) AS quarantine_count,
  (SELECT COUNT(*) FROM integrity_alarms
    WHERE workspace_id = ? AND resolved_at IS NULL) AS unresolved_alarm_count,
  (SELECT group_concat(DISTINCT kind) FROM integrity_alarms
    WHERE workspace_id = ? AND resolved_at IS NULL) AS alarm_kinds,
  (SELECT last_sync_completed_at FROM sync_cursors
    WHERE workspace_id = ?) AS last_synced_at
''';

  Selectable<QueryRow> _healthQuery() => _db.customSelect(
        _healthSql,
        variables: [
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
      unresolvedAlarmCount: row.read<int>('unresolved_alarm_count'),
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
      (_db.select(_db.quarantinedOps)
            ..where((row) => includeReleased
                ? row.workspaceId.equals(workspaceId)
                : row.workspaceId.equals(workspaceId) & row.releasedAt.isNull())
            ..orderBy([(row) => OrderingTerm(expression: row.id)]))
          .get();

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
