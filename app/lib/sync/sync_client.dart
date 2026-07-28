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

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'chain_verifier.dart';
import 'control_payload.dart';
import 'domain_projector.dart';
import 'envelope.dart';
import 'hlc.dart';
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
    if (existing != null && !_sameBytes(existing.rootPk, rootPk)) {
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
  Future<String> capture({
    required String collection,
    required String entityId,
    Map<String, Object?> fields = const {},
    bool tombstone = false,
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
    final opId = await _authorAndQueue(
      opClass: opClassContent,
      payload: payload.encode(),
    );
    final affected =
        await _reducer.apply(payload, authorMemberIdHex: identity.memberIdHex);
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
  Future<String> captureControl(Uint8List payload) =>
      _authorAndQueue(opClass: opClassControl, payload: payload);

  Future<String> _authorAndQueue({
    required int opClass,
    required Uint8List payload,
  }) async {
    final chain = await _authorChain();
    final header = OpHeader(
      workspaceId: workspaceId,
      opClass: opClass,
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
  /// Returns the post-sync [SyncHealth] — the surface that replaces PowerSync's
  /// status indicator.
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
  Future<void> flushOutbox() async {
    final pending = await (_db.select(_db.outbox)
          ..where((row) => row.workspaceId.equals(workspaceId) & row.sentAt.isNull())
          ..orderBy([(row) => OrderingTerm(expression: row.authorSeq)]))
        .get();
    if (pending.isEmpty) return;

    try {
      // A duplicate result is still an acknowledgement: the server holds the op.
      await transport.postOps(workspaceId, [for (final row in pending) row.envelope]);
    } on AuthorChainConflictException catch (conflict) {
      await _recordOwnWritesVerdict(conflict);
      return;
    }
    final sentAt = _now();
    for (final row in pending) {
      await (_db.update(_db.outbox)..where((r) => r.id.equals(row.id)))
          .write(OutboxCompanion(sentAt: Value(sentAt)));
    }
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
    // Projection is the tail of the receive order, one pass per batch: an
    // entity touched by three ops in one pull is projected once, from the
    // reduced state all three produced.
    await projector?.project(affected);
    await _stampPullCompleted();
  }

  /// A served op at or below the `since` it was asked past: alarm, and refuse it
  /// without applying.
  ///
  /// The alarm fires whatever the bytes are, because the *serving* is the
  /// accusation. What the bytes are decides how much more there is to say: the op
  /// we already hold at that seq is nothing further, and anything else is a
  /// second claim on a slot this device has spent — refused rather than written
  /// over, because the log is evidence and evidence is not edited.
  Future<void> _refuseStaleServe(PulledOp pulled, int since) async {
    OpHeader? header;
    try {
      header = OpHeader.parse(splitEnvelope(pulled.envelope).header);
    } on SyncRejection {
      header = null;
    }
    await _raiseAlarm(
      IntegrityAlarmKind.stalePrefixServed,
      authorMemberId: header?.authorMemberId,
      detail: 'seq ${pulled.seq} was served for a pull since $since',
    );
    final stored = await (_db.select(_db.opLog)
          ..where((row) => row.workspaceId.equals(workspaceId) & row.seq.equals(pulled.seq)))
        .getSingleOrNull();
    if (stored != null && _sameBytes(stored.envelope, pulled.envelope)) return;

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
    await _refuse(pulled, rejection, header);
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
        await _receiveControl(pulled, parts.body, header);
        // A control op reduces to nothing, so it contributes no projection
        // work; it is logged because later content ops from the same author
        // chain to it. Its `applied_at` is stamped at once — the directory
        // update *is* its apply, and it has already happened.
        await _logReceived(pulled, header, appliedAt: _now());
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
    if (_sameBytes(authored.envelope, envelope)) return;
    throw SyncRejection(
      SyncRejectionReason.ownWritesDivergence,
      'the server served this device\'s own author_seq ${header.authorSeq} with '
      'different bytes than the outbox holds; the local copy stands',
    );
  }

  /// Re-admit quarantined successors, one head + 1 lookup at a time, to fixpoint.
  ///
  /// Reorder heals; drop and fork do not, and that is what makes the three end in
  /// distinct surfaced states. Arrival order 3, 2, 1 converges in a single sync
  /// because every accepted op re-asks the same question — *is the op at head + 1
  /// in quarantine?* — and a hostile 500-op reorder is 500 iterations of one flat
  /// loop rather than 500 recursive frames.
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
        final candidate = await _quarantinedGapAt(
          authorMemberId,
          (head?.authorSeq ?? 0) + 1,
        );
        if (candidate == null) break;
        final seq = candidate.seq;
        if (seq == null) break;

        final OpHeader header;
        try {
          header = OpHeader.parse(splitEnvelope(candidate.envelope).header);
        } on SyncRejection {
          // A gap refusal implies a header that parsed, so this is unreachable;
          // stopping is still the only safe answer if it ever is not.
          break;
        }
        final verdict = await _chainVerdictFor(header, candidate.envelope);
        if (verdict.isRefusal) {
          // The missing predecessor arrived and this successor provably does not
          // chain to it: two incompatible continuations claim one position. It
          // stays quarantined — the predecessor is here, and it is not the one
          // this op was chained to.
          await _raiseAlarm(
            verdict.rejection!.reason == SyncRejectionReason.prevAuthorHashMismatch
                ? IntegrityAlarmKind.authorChainFork
                : verdict.alarm!,
            authorMemberId: authorMemberId,
            detail: 'author_seq ${header.authorSeq} did not become chain-valid '
                'when its predecessor arrived: ${verdict.rejection!.message}',
            quarantineOpRowId: candidate.id,
          );
          break;
        }
        // Released *before* re-entry: the loop is driven by the unreleased rows,
        // and a re-entry that refuses for some later reason must not leave this
        // candidate to be picked up forever.
        await _markReleased(candidate.id);
        releasedAny = true;
        affected.addAll(
          await _receive(PulledOp(seq: seq, envelope: candidate.envelope)),
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

  /// The one row that could now be chain-valid — a point lookup, not a walk.
  Future<QuarantineRow?> _quarantinedGapAt(String authorMemberId, int authorSeq) async {
    final rows = await (_db.select(_db.quarantinedOps)
          ..where((row) =>
              row.workspaceId.equals(workspaceId) &
              row.authorMemberId.equals(authorMemberId) &
              row.authorSeq.equals(authorSeq) &
              row.releasedAt.isNull() &
              row.reason.equals(SyncRejectionReason.authorChainGap.code))
          ..orderBy([(row) => OrderingTerm(expression: row.id)])
          ..limit(1))
        .get();
    return rows.isEmpty ? null : rows.first;
  }

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

  /// The six-step MemberRegister verification, in order, before the directory
  /// learns anything.
  ///
  /// Step 4 is the load-bearing one. A genuine certificate is public the moment
  /// it is in the log; without checking the envelope signature against the
  /// certificate's *own* key, anyone holding a copy could wrap it around
  /// self-signed envelopes and manufacture forks in the victim's chain.
  Future<void> _receiveControl(PulledOp pulled, Uint8List body, OpHeader header) async {
    // 1. Parse the payload.
    final payloadBytes = parseBody(body);
    final payload = ControlPayload.decode(payloadBytes);
    payload.requireServedType();

    final rootPk = await pinnedRootPk();
    if (rootPk == null) {
      throw const SyncRejection(
        SyncRejectionReason.badRootSignature,
        'no Root is pinned on this device, so no registration can be verified',
      );
    }
    // 2. Root's signature, over the certificate's literal bytes.
    await verifyRegistrationCertificate(payload.certBytes, payload.rootSig, rootPk);
    final certificate = payload.certificate();

    // 3. The certificate must be about this envelope's author.
    if (certificate.memberId != header.authorMemberId) {
      throw SyncRejection(
        SyncRejectionReason.badRootSignature,
        'certificate names ${certificate.memberId}, envelope author is '
        '${header.authorMemberId}',
      );
    }
    // 4. The certificate's key must actually have signed this envelope.
    await verifyEnvelope(pulled.envelope, certificate.signPk);
    // 5. …and must be the key the header names.
    if (!_sameBytes(certificate.signKeyId, header.authorKeyId)) {
      throw const SyncRejection(
        SyncRejectionReason.badRootSignature,
        'certificate key id is not the one the header names',
      );
    }
    // 6. Position and chain.
    if (header.authorSeq != 1) {
      throw SyncRejection(
        SyncRejectionReason.controlChainBreak,
        'a member_register must be its author\'s first op, not seq '
        '${header.authorSeq}',
      );
    }
    final chain = await _controlChain();
    final expectedPrevHash = chain?.lastControlPayloadHash ?? zeroPrevControlHash;
    if (!_sameBytes(payload.prevControlHash, expectedPrevHash)) {
      // A zero hash arriving when control ops have been applied is a fork
      // candidate, never a benign "fresh chain".
      throw SyncRejection(
        SyncRejectionReason.controlChainBreak,
        'prev_control_hash does not name the last applied control op '
        '(${chain?.appliedCount ?? 0} applied)',
      );
    }

    directory.rememberChained(certificate);
    await _db.into(_db.controlChainState).insertOnConflictUpdate(
          ControlChainStateCompanion.insert(
            workspaceId: workspaceId,
            lastControlPayloadHash: controlPayloadHash(payloadBytes),
            appliedCount: (chain?.appliedCount ?? 0) + 1,
          ),
        );
  }

  Future<ControlChainRow?> _controlChain() => (_db.select(_db.controlChainState)
        ..where((row) => row.workspaceId.equals(workspaceId)))
      .getSingleOrNull();

  /// The chain link a control op this device authors next must name.
  Future<Uint8List> appliedControlHead() async =>
      (await _controlChain())?.lastControlPayloadHash ?? zeroPrevControlHash;

  /// Append to the log, or record that the append itself was refused.
  ///
  /// Returns false when the op could not be logged and must be skipped. The only
  /// way that happens is the unique chain-slot constraint firing — a position
  /// double-logged past the verdict, which is either a bug here or a duplicate a
  /// hostile server slipped through. Either way it is an integrity event to
  /// surface and skip: throwing would abort the rest of the page, letting one
  /// poisoned position stall every op behind it.
  Future<bool> _logReceived(
    PulledOp pulled,
    OpHeader header, {
    DateTime? appliedAt,
  }) async {
    try {
      await _db.into(_db.opLog).insertOnConflictUpdate(
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
    } on Object catch (error) {
      // Deliberately broad: whatever stopped this one op from being logged, the
      // page must survive it, and the alarm is what makes the loss visible.
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

  /// Quarantine a refusal and raise whatever accusation it escalates to.
  Future<void> _refuse(
    PulledOp pulled,
    SyncRejection rejection,
    OpHeader? header,
  ) async {
    final quarantineRowId = await _quarantine(pulled, rejection, header);
    final alarm = alarmForRejection(rejection.reason);
    if (alarm == null) return;
    await _raiseAlarm(
      alarm,
      authorMemberId: header?.authorMemberId,
      detail: rejection.message,
      quarantineOpRowId: quarantineRowId,
    );
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
      if (_sameBytes(row.envelope, pulled.envelope)) return row.id;
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

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}
