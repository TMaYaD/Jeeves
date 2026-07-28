/// Capture, push, pull, reduce — the client half of the walking skeleton.
///
/// `sync()` is explicit and this class stays a verb-set: staying subscribed to
/// the payload-free "there's news" signal is a policy, and it lives in
/// `signal_listener.dart`. Everything else is here — the offline queue is
/// simply the outbox surviving a failed POST, and the pull loop runs the
/// fail-closed receive pipeline before anything reaches the reducer.
library;

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'envelope.dart';
import 'hlc.dart';
import 'member_identity.dart';
import 'op_payload.dart';
import 'reducer.dart';
import 'sync_database.dart';
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
    await _reducer.apply(payload, authorMemberIdHex: identity.memberIdHex);
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
  Future<void> sync() async {
    await flushOutbox();
    await pull();
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
    while (hasMore) {
      final page = await transport.pullOps(
        workspaceId,
        since: cursor,
        limit: pullPageLimit,
      );
      for (final pulled in page.ops) {
        await _receive(pulled);
        cursor = pulled.seq;
        await _saveCursor(cursor);
      }
      hasMore = page.hasMore && page.ops.isNotEmpty;
    }
  }

  /// The fail-closed receive pipeline, in its normative order.
  ///
  /// `backend/tests/sync/test_envelope_vectors.py` runs the same sequence
  /// against the same negative vectors, so the two stay in step. A refusal
  /// quarantines the op and the stream continues: one bad op from a server
  /// must not be able to stall a device.
  Future<void> _receive(PulledOp pulled) async {
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
      await _reducer.apply(
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
    } on SyncRejection catch (rejection) {
      await _quarantine(pulled, rejection);
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
