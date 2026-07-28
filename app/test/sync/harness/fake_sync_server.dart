/// An in-process stand-in for `backend/app/sync/routes.py`.
///
/// It exists so N simulated devices can converge in a `flutter test` run with
/// no server, no network and no clock — the coverage gap ADR-0026 set out to
/// close. It is only worth anything if it behaves like the real server, so
/// `test/sync/fake_sync_server_contract_test.dart` mirrors
/// `backend/tests/sync/test_ops_routes.py` case-for-case and both sides load
/// the same golden vectors.
///
/// Content-blind, exactly like the real one: it reads the 158-byte header and
/// the member registry, and never a body.
library;

import 'dart:typed_data';

import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/sync_transport.dart';

/// One appended op, plus the header fields the server indexes it by.
class StoredOp {
  StoredOp({
    required this.seq,
    required this.workspaceId,
    required this.envelope,
    required this.header,
    this.compactedBy,
  });

  final int seq;
  final String workspaceId;
  final Uint8List envelope;

  /// Null only for rows put there by [FakeSyncServer.injectUnchecked] whose
  /// bytes do not parse — a server that skips its own validations can store
  /// anything, and the client must survive being served it.
  final OpHeader? header;

  /// Set by a prune op (#555). v1 prunes are soft deletes: default pulls hide
  /// the row, nothing is removed.
  int? compactedBy;
}

class _RegisteredMember {
  _RegisteredMember(this.userId, this.record);

  final String userId;
  final MemberRecord record;
}

/// Guards the single-transaction batch, mirroring `MAX_OPS_PER_BATCH`.
const int fakeServerMaxOpsPerBatch = 1000;

class FakeSyncServer {
  final List<StoredOp> _log = [];
  final Map<String, _RegisteredMember> _members = {};
  int _nextSeq = 1;

  /// Every batch the server accepted for a POST, in order — lets a test assert
  /// what actually went over the wire.
  final List<List<Uint8List>> receivedBatches = [];

  List<StoredOp> get storedOps => List.unmodifiable(_log);

  /// A connection authenticated as [userId]. The real server derives the same
  /// scope from the JWT; #548 narrows both to a member-scoped token.
  FakeSyncServerSession connectAs(String userId) =>
      FakeSyncServerSession(this, userId);

  /// Test hook for #555's soft delete, which has no client-side emitter yet.
  void markCompacted(int seq, {required int by}) {
    _log.firstWhere((op) => op.seq == seq).compactedBy = by;
  }

  /// Append bytes without running any of the server's own checks.
  ///
  /// This is the *hostile or broken server*: the fail-closed rules on the
  /// client exist precisely because nothing stops a server from serving an
  /// envelope it should have refused, or one it forged. Returns the assigned
  /// seq.
  int injectUnchecked(String workspaceId, Uint8List envelope) {
    OpHeader? header;
    try {
      header = OpHeader.parse(envelope);
    } on SyncRejection {
      header = null;
    }
    final op = StoredOp(
      seq: _nextSeq++,
      workspaceId: workspaceId,
      envelope: envelope,
      header: header,
    );
    _log.add(op);
    return op.seq;
  }

  // --- The endpoints ---------------------------------------------------------

  MemberRecord _registerMember(
    String userId,
    String memberId,
    Uint8List signPk,
  ) {
    if (signPk.length != signPublicKeyBytes) {
      throw SyncTransportException(422, 'sign_pk must be $signPublicKeyBytes bytes');
    }
    final existing = _members[memberId];
    if (existing != null) {
      if (existing.userId != userId ||
          !_sameBytes(existing.record.signPk, signPk)) {
        throw const SyncTransportException(
          409,
          'Member id already registered with a different key',
        );
      }
      return existing.record;
    }
    // Server-derived, never a client claim.
    final record = MemberRecord(
      memberId: memberId,
      signPk: signPk,
      keyId: deriveKeyId(signPk),
    );
    _members[memberId] = _RegisteredMember(userId, record);
    return record;
  }

  List<MemberRecord> _listMembers(String userId, String workspaceId) {
    _authorizeWorkspace(userId, workspaceId);
    return [
      for (final member in _members.values)
        if (member.userId == userId) member.record,
    ];
  }

  List<OpAppendResult> _postOps(
    String userId,
    String workspaceId,
    List<Uint8List> envelopes,
  ) {
    _authorizeWorkspace(userId, workspaceId);
    if (envelopes.length > fakeServerMaxOpsPerBatch) {
      throw const SyncTransportException(413, 'Batch too large');
    }

    final parsed = <OpHeader>[];
    for (var index = 0; index < envelopes.length; index++) {
      final envelope = envelopes[index];
      final OpHeader header;
      try {
        header = OpHeader.parse(envelope);
        if (envelope.length < minimumEnvelopeBytes) {
          throw SyncRejection(
            SyncRejectionReason.envelopeTooShort,
            'envelope is ${envelope.length} bytes, the shortest legal one is '
            '$minimumEnvelopeBytes',
          );
        }
        header.checkServed();
      } on SyncRejection catch (rejection) {
        throw SyncTransportException(422, 'ops[$index]: ${rejection.reason.code}');
      }
      if (header.workspaceId != workspaceId) {
        throw SyncTransportException(422, 'ops[$index]: workspace_mismatch');
      }
      parsed.add(header);
    }
    if (parsed.isEmpty) {
      receivedBatches.add(const []);
      return const [];
    }

    for (final header in parsed) {
      final member = _members[header.authorMemberId];
      if (member == null || member.userId != userId) {
        throw const SyncTransportException(
          403,
          'Author is not a member registered to this user',
        );
      }
    }

    final lastAuthorSeq = <String, int>{};
    for (final op in _log) {
      final storedHeader = op.header;
      if (op.workspaceId != workspaceId || storedHeader == null) continue;
      final current = lastAuthorSeq[storedHeader.authorMemberId] ?? 0;
      if (storedHeader.authorSeq > current) {
        lastAuthorSeq[storedHeader.authorMemberId] = storedHeader.authorSeq;
      }
    }
    int? existingSeq(String author, String opId) {
      for (final op in _log) {
        final storedHeader = op.header;
        if (op.workspaceId == workspaceId &&
            storedHeader != null &&
            storedHeader.authorMemberId == author &&
            storedHeader.opId == opId) {
          return op.seq;
        }
      }
      return null;
    }

    // Validate the whole batch before appending any of it: a gap means the
    // author's chain is broken, and accepting the tail would make it permanent.
    final staged = <String, StoredOp>{};
    final plan = <({String opId, StoredOp? op, int? seq, bool duplicate})>[];
    for (var index = 0; index < parsed.length; index++) {
      final header = parsed[index];
      final key = '${header.authorMemberId}/${header.opId}';
      final alreadyStored = existingSeq(header.authorMemberId, header.opId);
      if (alreadyStored != null) {
        plan.add((opId: header.opId, op: null, seq: alreadyStored, duplicate: true));
        continue;
      }
      if (staged.containsKey(key)) {
        plan.add((opId: header.opId, op: staged[key], seq: null, duplicate: true));
        continue;
      }
      final expected = (lastAuthorSeq[header.authorMemberId] ?? 0) + 1;
      if (header.authorSeq != expected) {
        throw SyncTransportException(
          409,
          'ops[$index]: author_seq ${header.authorSeq}, expected $expected',
        );
      }
      final op = StoredOp(
        seq: _nextSeq++,
        workspaceId: workspaceId,
        envelope: envelopes[index],
        header: header,
      );
      staged[key] = op;
      lastAuthorSeq[header.authorMemberId] = header.authorSeq;
      plan.add((opId: header.opId, op: op, seq: null, duplicate: false));
    }

    _log.addAll(staged.values);
    receivedBatches.add(List.unmodifiable(envelopes));
    return [
      for (final entry in plan)
        OpAppendResult(
          opId: entry.opId,
          seq: entry.seq ?? entry.op!.seq,
          duplicate: entry.duplicate,
        ),
    ];
  }

  PullPage _pullOps(
    String userId,
    String workspaceId, {
    required int since,
    required int limit,
  }) {
    _authorizeWorkspace(userId, workspaceId);
    final matching = [
      for (final op in _log)
        if (op.workspaceId == workspaceId && op.seq > since && op.compactedBy == null)
          op,
    ]..sort((a, b) => a.seq.compareTo(b.seq));
    final page = matching.take(limit).toList();
    return PullPage(
      ops: [for (final op in page) PulledOp(seq: op.seq, envelope: op.envelope)],
      hasMore: matching.length > limit,
    );
  }

  void _authorizeWorkspace(String userId, String workspaceId) {
    if (workspaceId != implicitWorkspaceId(userId)) {
      throw const SyncTransportException(403, 'No grant for this workspace');
    }
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }
}

/// One authenticated connection to [FakeSyncServer].
class FakeSyncServerSession implements SyncTransport {
  FakeSyncServerSession(this.server, this.userId);

  final FakeSyncServer server;
  final String userId;

  String get workspaceId => implicitWorkspaceId(userId);

  @override
  Future<MemberRecord> registerMember({
    required String memberId,
    required Uint8List signPk,
  }) async =>
      server._registerMember(userId, memberId, signPk);

  @override
  Future<List<MemberRecord>> fetchMembers(String workspaceId) async =>
      server._listMembers(userId, workspaceId);

  @override
  Future<List<OpAppendResult>> postOps(
    String workspaceId,
    List<Uint8List> envelopes,
  ) async =>
      server._postOps(userId, workspaceId, envelopes);

  @override
  Future<PullPage> pullOps(
    String workspaceId, {
    required int since,
    required int limit,
  }) async =>
      server._pullOps(userId, workspaceId, since: since, limit: limit);
}
