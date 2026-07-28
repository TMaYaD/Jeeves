/// Capture, push, pull, verify, reduce — the client half of the sync spine.
///
/// `sync()` is explicit and this class stays a verb-set: staying subscribed to
/// the payload-free "there's news" signal is a policy, and it lives in
/// `signal_listener.dart`. Everything else is here — the offline queue is
/// simply the outbox surviving a failed POST, and the pull loop runs the
/// fail-closed receive pipeline before anything reaches the reducer.
///
/// **The receive order is normative** and shared with #551:
///
/// ```
/// verifyEnvelope -> parseBody -> op_class routing -> per-author chain verdict
///                -> reducer guards -> apply
/// ```
///
/// with one named carve-out: for `op_class = 2` the envelope-signature check
/// **defers** out of the first stage and into step 4 of the control
/// verification below. A MemberRegister's author key is unknowable before its
/// certificate parses — the directory by definition has no entry for an author
/// that is registering itself. The deviation is confined to control ops and
/// ends at that step; nothing else skips or reorders `verifyEnvelope`.
///
/// There is no `refreshMemberDirectory`. A MemberRegister is its author's op 1
/// and seq ordering guarantees it is pulled before any of that author's content
/// ops, so the pull itself hydrates the directory in order. A directory refresh
/// racing a pull is not a hazard this client manages; it is a hazard this
/// client cannot have.
library;

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'control_payload.dart';
import 'envelope.dart';
import 'hlc.dart';
import 'member_identity.dart';
import 'op_payload.dart';
import 'reducer.dart';
import 'recovery_escrow.dart';
import 'sync_database.dart';
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

  SyncTransport? _transport;

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
    await _reducer.apply(payload, authorMemberIdHex: identity.memberIdHex);
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

      if (header.opClass == opClassControl) {
        await _receiveControl(pulled, parts.body, header);
      } else {
        final signPk = directory.publicKeyFor(header.authorMemberId, header.authorKeyId);
        await verifyEnvelope(pulled.envelope, signPk);
        final payload = OpPayload.decode(parseBody(parts.body));
        await _reducer.apply(
          payload,
          authorMemberIdHex: memberIdToHex(header.authorMemberId),
        );
        _clock.receive(payload.hlc);
      }
      await _logReceived(pulled, header);
    } on SyncRejection catch (rejection) {
      await _quarantine(pulled, rejection);
    }
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

  Future<void> _logReceived(PulledOp pulled, OpHeader header) async {
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

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}
