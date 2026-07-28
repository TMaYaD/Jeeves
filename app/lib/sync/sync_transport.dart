/// The transport seam between the sync client and a server.
///
/// Two implementations exist: [HttpSyncTransport] for a real server, and the
/// in-process double in `test/sync/harness/fake_sync_server.dart` that the
/// multi-device harness runs against. The double is held to the same contract
/// by a test file that mirrors `backend/tests/sync/test_ops_routes.py`
/// case-for-case.
library;

import 'dart:typed_data';

/// A Member's registered signing key. Enrolment only — a registry row confers
/// no authority until #548's Root-signed control ops.
class MemberRecord {
  const MemberRecord({
    required this.memberId,
    required this.signPk,
    required this.keyId,
  });

  final String memberId;
  final Uint8List signPk;

  /// Server-derived: the first 8 bytes of SHA-256 over [signPk].
  final Uint8List keyId;
}

/// One op's fate in a batch append.
class OpAppendResult {
  const OpAppendResult({
    required this.opId,
    required this.seq,
    required this.duplicate,
  });

  final String opId;
  final int seq;
  final bool duplicate;
}

class PulledOp {
  const PulledOp({required this.seq, required this.envelope});

  final int seq;
  final Uint8List envelope;
}

class PullPage {
  const PullPage({required this.ops, required this.hasMore});

  final List<PulledOp> ops;
  final bool hasMore;
}

/// A transport-level failure. [statusCode] is null when the server could not be
/// reached at all — the offline case, which leaves the outbox intact.
class SyncTransportException implements Exception {
  const SyncTransportException(this.statusCode, this.detail);

  const SyncTransportException.unreachable(this.detail) : statusCode = null;

  final int? statusCode;
  final String detail;

  bool get isUnreachable => statusCode == null;

  @override
  String toString() => 'SyncTransportException(${statusCode ?? 'unreachable'}): $detail';
}

abstract class SyncTransport {
  Future<MemberRecord> registerMember({
    required String memberId,
    required Uint8List signPk,
  });

  Future<List<MemberRecord>> fetchMembers(String workspaceId);

  /// Append in order, in one transaction. Idempotent by author-namespaced op id.
  Future<List<OpAppendResult>> postOps(
    String workspaceId,
    List<Uint8List> envelopes,
  );

  /// `since` is a pure client parameter — no server-side cursor exists (F17).
  Future<PullPage> pullOps(
    String workspaceId, {
    required int since,
    required int limit,
  });
}
