/// Capture, push, pull, reduce — the client half of the walking skeleton.
///
/// `sync()` is explicit: there is no socket in this slice (#552 adds the
/// payload-free "there's news" signal). Everything else is here — the offline
/// queue is simply the outbox surviving a failed POST, and the pull loop runs
/// the fail-closed receive pipeline before anything reaches the reducer.
library;

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'domain_projector.dart';
import 'envelope.dart';
import 'hlc.dart';
import 'member_identity.dart';
import 'op_payload.dart';
import 'reducer.dart';
import 'sync_database.dart';
import 'sync_health.dart';
import 'sync_transport.dart';

/// not tunable per call: one page is a batch of ops, sized to keep a bootstrap
/// pull to a handful of round-trips without an unbounded response body.
const int defaultPullPageLimit = 500;

class SyncClient {
  SyncClient({
    required this.workspaceId,
    required this.identity,
    required this.transport,
    required SyncDatabase database,
    required HlcClock clock,
    required Reducer reducer,
    MemberDirectory? directory,
    this.pullPageLimit = defaultPullPageLimit,
    DateTime Function()? now,
  })  : _db = database,
        _clock = clock,
        _reducer = reducer,
        directory = directory ?? MemberDirectory(),
        _now = now ?? DateTime.now;

  final String workspaceId;
  final MemberIdentity identity;
  final SyncTransport transport;
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

  // --- Enrolment ------------------------------------------------------------

  /// Register this device's public key and pull the registry back.
  Future<void> enrol() async {
    final record = await transport.registerMember(
      memberId: identity.memberId,
      signPk: identity.signPk,
    );
    directory.remember(record);
    await refreshMemberDirectory();
  }

  Future<void> refreshMemberDirectory() async {
    directory.rememberAll(await transport.fetchMembers(workspaceId));
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
    final chain = await _authorChain();
    final header = OpHeader(
      workspaceId: workspaceId,
      opId: _newOpId(),
      authorMemberId: identity.memberId,
      authorKeyId: identity.keyId,
      authorSeq: chain.nextAuthorSeq,
      prevAuthorHash: chain.lastEnvelopeHash,
    );
    final envelope = await identity.signer.buildEnvelope(
      header,
      frameBody(payload.encode()),
    );

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
    final affected =
        await _reducer.apply(payload, authorMemberIdHex: identity.memberIdHex);
    // The authoring device projects its own op too: that is what applies the
    // widened cascade and the `focus_session_tasks.id` realignment locally,
    // rather than leaving the author as the one device whose rows differ.
    await projector?.project(affected);
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

  Future<void> flushOutbox() async {
    final pending = await (_db.select(_db.outbox)
          ..where((row) => row.workspaceId.equals(workspaceId) & row.sentAt.isNull())
          ..orderBy([(row) => OrderingTerm(expression: row.authorSeq)]))
        .get();
    if (pending.isEmpty) return;

    // A duplicate result is still an acknowledgement: the server holds the op.
    await transport.postOps(workspaceId, [for (final row in pending) row.envelope]);
    final sentAt = _now();
    for (final row in pending) {
      await (_db.update(_db.outbox)..where((r) => r.id.equals(row.id)))
          .write(OutboxCompanion(sentAt: Value(sentAt)));
    }
  }

  Future<void> pull() async {
    var cursor = await _cursor();
    var hasMore = true;
    final affected = <AffectedEntity>{};
    while (hasMore) {
      final page = await transport.pullOps(
        workspaceId,
        since: cursor,
        limit: pullPageLimit,
      );
      for (final pulled in page.ops) {
        affected.addAll(await _receive(pulled));
        cursor = pulled.seq;
        await _saveCursor(cursor);
      }
      hasMore = page.hasMore && page.ops.isNotEmpty;
    }
    // Projection is the tail of the receive order, one pass per batch: an
    // entity touched by three ops in one pull is projected once, from the
    // reduced state all three produced.
    await projector?.project(affected);
    await _stampPullCompleted();
  }

  /// The fail-closed receive pipeline, in its normative order.
  ///
  /// `backend/tests/sync/test_envelope_vectors.py` runs the same sequence
  /// against the same negative vectors, so the two stay in step. A refusal
  /// quarantines the op and the stream continues: one bad op from a server
  /// must not be able to stall a device.
  Future<Set<AffectedEntity>> _receive(PulledOp pulled) async {
    try {
      final parts = splitEnvelope(pulled.envelope);
      final header = OpHeader.parse(parts.header);
      header.checkServed();
      if (header.workspaceId != workspaceId) {
        // Not a filtered row: a header disagreeing with the stream it arrived
        // in is a server-integrity event (review F6).
        throw SyncRejection(
          SyncRejectionReason.workspaceMismatch,
          'envelope names workspace ${header.workspaceId}, pulled from $workspaceId',
        );
      }
      final signPk = directory.publicKeyFor(header.authorMemberId, header.authorKeyId);
      await verifyEnvelope(pulled.envelope, signPk);
      final payload = OpPayload.decode(parseBody(parts.body));
      final affected = await _reducer.apply(
        payload,
        authorMemberIdHex: memberIdToHex(header.authorMemberId),
      );
      _clock.receive(payload.hlc);
      await _db.into(_db.opLog).insertOnConflictUpdate(
            OpLogCompanion.insert(
              seq: pulled.seq,
              workspaceId: workspaceId,
              envelope: pulled.envelope,
              opId: header.opId,
              authorMemberId: header.authorMemberId,
              authorSeq: header.authorSeq,
              receivedAt: _now(),
            ),
          );
      return affected;
    } on SyncRejection catch (rejection) {
      await _quarantine(pulled, rejection);
      return const {};
    }
  }

  Future<void> _quarantine(PulledOp pulled, SyncRejection rejection) async {
    await _db.into(_db.quarantinedOps).insert(
          QuarantinedOpsCompanion.insert(
            workspaceId: workspaceId,
            seq: Value(pulled.seq),
            reason: rejection.reason.code,
            detail: rejection.message,
            envelope: pulled.envelope,
            detectedAt: _now(),
          ),
        );
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
    WHERE workspace_id = ?) AS quarantine_count,
  (SELECT last_sync_completed_at FROM sync_cursors
    WHERE workspace_id = ?) AS last_synced_at
''';

  Selectable<QueryRow> _healthQuery() => _db.customSelect(
        _healthSql,
        variables: [
          Variable<String>(workspaceId),
          Variable<String>(workspaceId),
          Variable<String>(workspaceId),
        ],
        readsFrom: {_db.outbox, _db.quarantinedOps, _db.syncCursors},
      );

  static SyncHealth _readHealth(QueryRow row) => SyncHealth(
        pendingOpCount: row.read<int>('pending_op_count'),
        quarantineCount: row.read<int>('quarantine_count'),
        // #551 fills these from its IntegrityAlarms rows with
        // `resolved_at IS NULL`; until then quarantineCount carries the signal.
        unresolvedAlarmCount: 0,
        alarmKinds: const <String>{},
        lastSyncedAt: row.read<DateTime?>('last_synced_at'),
      );

  Future<SyncHealth> health() async => _readHealth(await _healthQuery().getSingle());

  Stream<SyncHealth> watchSyncHealth() =>
      _healthQuery().watchSingle().map(_readHealth);

  // --- Quarantine surface ----------------------------------------------------

  Future<List<QuarantineRow>> quarantined() =>
      (_db.select(_db.quarantinedOps)
            ..where((row) => row.workspaceId.equals(workspaceId))
            ..orderBy([(row) => OrderingTerm(expression: row.id)]))
          .get();

  /// Watchable so the UI can surface "something arrived that we refused" rather
  /// than swallowing it.
  Stream<int> watchQuarantineCount() => (_db.selectOnly(_db.quarantinedOps)
        ..addColumns([_db.quarantinedOps.id.count()])
        ..where(_db.quarantinedOps.workspaceId.equals(workspaceId)))
      .map((row) => row.read(_db.quarantinedOps.id.count()) ?? 0)
      .watchSingle();

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
