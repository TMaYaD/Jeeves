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

import 'dart:math' show min;

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
import 'envelope.dart';
import 'grants_view.dart';
import 'hlc.dart';
import 'ids.dart';
import 'member_identity.dart';
import 'op_payload.dart';
import 'reducer.dart';
import 'recovery_escrow.dart';
import 'sync_database.dart';
import 'sync_health.dart';
import 'sync_transport.dart';

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
    this.pullPageLimit = defaultPullPageLimit,
    DateTime Function()? now,
  })  : _db = database,
        _clock = clock,
        _reducer = reducer,
        _transport = transport,
        directory = directory ?? MemberDirectory(),
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

  SyncTransport? _transport;

  /// The author whose quarantined successors the release scan is currently
  /// re-admitting, or null.
  ///
  /// Re-entry suppression, and the reason the fixpoint is one flat loop: a
  /// released op goes back through [_receive], and if that call started a nested
  /// scan of its own then a hostile 500-op reorder would heal in 500 recursive
  /// frames instead of 500 iterations.
  String? _releasingChainOfAuthor;

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
    final chain = await _authorChain();
    final header = OpHeader(
      workspaceId: workspaceId,
      opClass: opClass,
      keyEpoch: keyEpoch,
      opId: _newOpId(),
      authorMemberId: identity.memberId,
      authorKeyId: identity.keyId,
      authorSeq: chain.nextAuthorSeq,
      prevAuthorHash: chain.lastEnvelopeHash,
    );
    final envelope = await identity.signer.buildEnvelope(header, frameBody(payload));

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
    if (_rebuildRequired) {
      // A control fork resolved during this pull, so the authorization verdicts
      // the content ops applied under are no longer the right ones.
      affected.addAll(await rebuildFromOpLog());
    }
    // Projection is the tail of the receive order, one pass per batch: an
    // entity touched by three ops in one pull is projected once, from the
    // reduced state all three produced.
    await projector?.project(affected);
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
        if (header.opClass == opClassControl) continue;
        payload = OpPayload.decode(parseBody(parts.body));
      } on SyncRejection {
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
        final verified = await _verifyControlOp(pulled, parts.body, header);
        if (!await _logReceived(pulled, header)) return const {};
        try {
          await _applyControlOp(pulled, header, verified);
        } on SyncRejection catch (rejection) {
          // Logged-but-refused, the same shape the content path uses: the envelope
          // stays as chain evidence, no authority effect landed, and the row
          // records which guard fired. Rethrown so the outer catch still
          // quarantines and accuses.
          await _stampRefused(pulled.seq, rejection.reason);
          rethrow;
        }
        // A control op reduces to nothing, so it contributes no projection work;
        // it is logged because later content ops from the same author chain to it.
        // `applied_at` is stamped only now — after verification and application
        // both succeeded — so a refused control op is logged-but-unapplied
        // evidence rather than a row claiming an apply that never happened.
        await _stampApplied(pulled.seq);
        return const {};
      }

      final signPk = directory.publicKeyFor(header.authorMemberId, header.authorKeyId);
      await verifyEnvelope(pulled.envelope, signPk);
      final payload = OpPayload.decode(parseBody(parts.body));

      final verdict = await _chainVerdictFor(header, pulled.envelope);
      if (verdict.isRefusal) throw verdict.rejection!;
      await _checkOwnWrites(header, pulled.envelope);
      if (verdict.outcome == ChainOutcome.idempotentSkip) {
        // Already held, byte for byte. Nothing to log, nothing to re-apply, and
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

  // --- Per-author chain enforcement -------------------------------------------

  /// The chain rules, against what this device's log already holds.
  Future<ChainVerdict> _chainVerdictFor(OpHeader header, Uint8List envelope) async =>
      chainVerdict(
        header: header,
        envelope: envelope,
        head: await _chainHead(header.authorMemberId),
        storedAtAuthorSeq: await _storedAtAuthorSeq(
          header.authorMemberId,
          header.authorSeq,
        ),
        storedUnderOpId: await _storedUnderOpId(header.authorMemberId, header.opId),
        // #555's prune attestation is the only thing that can supply a floor, and
        // it does not exist yet. Passing null keeps the rule visible at the one
        // call site that will have to supply it.
        verifiedFloor: null,
      );

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
  Future<Set<AffectedEntity>> _releaseChainSuccessors(String authorMemberId) async {
    if (_releasingChainOfAuthor != null) return const {};
    _releasingChainOfAuthor = authorMemberId;
    final affected = <AffectedEntity>{};
    var releasedAny = false;
    try {
      while (true) {
        final head = await _chainHead(authorMemberId);
        final claimants = await _quarantinedGapClaimantsAt(
          authorMemberId,
          (head?.authorSeq ?? 0) + 1,
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
        // Released *before* re-entry: the loop is driven by the unreleased rows,
        // and a re-entry that refuses for some later reason must not leave this
        // claimant to be picked up forever. Losers keep no `released_at` and are
        // re-alarmed at most once per iteration — if the winner's re-receive
        // refuses, the head does not advance and the next iteration sees them
        // again — and the loop still terminates because the unreleased set at the
        // contested position strictly shrinks on every pass.
        await _markReleased(winner.id);
        releasedAny = true;
        affected.addAll(
          await _receive(PulledOp(seq: winner.seq!, envelope: winner.envelope)),
        );
      }
      if (releasedAny) {
        await _raiseAlarm(
          IntegrityAlarmKind.authorStreamReordered,
          authorMemberId: authorMemberId,
          detail: 'quarantined successors became chain-valid as their '
              'predecessors arrived',
        );
        // The standing-gap rule: the gap alarm is only reclassified away once
        // nothing is still missing. While one refused row stands unreleased, the
        // reorder is recorded alongside the gap rather than instead of it.
        if (!await _hasUnreleasedGap(authorMemberId)) {
          await _resolveAlarm(IntegrityAlarmKind.authorChainGap, authorMemberId);
        }
      }
    } finally {
      _releasingChainOfAuthor = null;
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
        if (!sameBytes(genesis.rootPk, rootPk)) {
          // The Root inside the signed genesis must be the Root this device
          // pinned: that cross-check is why it is in there at all.
          throw const SyncRejection(
            SyncRejectionReason.badRootSignature,
            'the genesis names a different Root than this device pinned',
          );
        }
        if (genesis.workspaceId != workspaceId) {
          throw SyncRejection(
            SyncRejectionReason.workspaceMismatch,
            'genesis names workspace ${genesis.workspaceId}, pulled from $workspaceId',
          );
        }
        learned = genesis.asRegistration();
        await _bindRegistrationToEnvelope(learned, pulled, header);

      case controlTypeMemberRegister:
        await verifyRegistrationCertificate(payload.certBytes, payload.rootSig, rootPk);
        final certificate = payload.certificate();
        if (certificate.workspaceId != workspaceId) {
          throw SyncRejection(
            SyncRejectionReason.workspaceMismatch,
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
  Future<void> _applyControlOp(
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

    // Verified *and* positioned: now the op may teach this device something.
    final learned = verified.learned;
    if (learned != null) directory.rememberChained(learned);
    if (payload.controlType == controlTypeWorkspaceGenesis) {
      // Genesis fixes the epoch floor at 0. Recorded rather than assumed, so a
      // Workspace's floor exists from the moment the Workspace does.
      await raiseEpochFloor(0);
    }
    await _appendAppliedControlOp(pulled, payload, header, verified.payloadBytes);
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
        SyncRejectionReason.workspaceMismatch,
        'grant names workspace ${grant.workspaceId}, pulled from $workspaceId',
      );
    }
    if (grant.granter != payload.authority) {
      // The signed certificate names its own granter; the payload's field only
      // says which key to check it against.
      throw const SyncRejection(
        SyncRejectionReason.badGrantSignature,
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
        SyncRejectionReason.workspaceMismatch,
        'revoke names workspace ${revoke.workspaceId}, pulled from $workspaceId',
      );
    }
    if (revoke.revoker != payload.authority) {
      throw const SyncRejection(
        SyncRejectionReason.badRevokeSignature,
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
      throw SyncRejection(
        SyncRejectionReason.badGrantSignature,
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
  /// A named, surfaced state *now*, dormant until #554: with no KeyWraps the
  /// predicate is defined against epoch 0 and never fires. The vocabulary and the
  /// seam land here so #554 wires delivery rather than concepts.
  Future<List<DerivedGrant>> orphanedGrants() async =>
      (await grantsView()).orphanedGrants().toList();

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

  // --- epoch_floor ------------------------------------------------------------

  /// The monotone `key_epoch` floor for this Workspace. Absent reads as 0.
  Future<int> epochFloor() async {
    final row = await (_db.select(_db.epochFloors)
          ..where((r) => r.workspaceId.equals(workspaceId)))
        .getSingleOrNull();
    return row?.keyEpochFloor ?? 0;
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
