/// The transport seams between the sync client and a server.
///
/// There are two, because there are two credentials (ADR-0028's authorization
/// matrix). [UserTransport] is what a Device can reach with the User's session:
/// register public keys, read and write the recovery escrow, and prove
/// possession of a device key to get a member credential. [SyncTransport] is
/// that member credential's surface: post and pull ops, and nothing else.
///
/// Splitting them is not tidiness. A stolen user session must not be able to
/// speak as a Device (review F10), and a type that offers both operations under
/// one credential is an invitation to write the code that lets it.
///
/// Two implementations exist of each: the HTTP ones for a real server, and the
/// in-process double in `test/sync/harness/fake_sync_server.dart` that the
/// multi-device harness runs against. The double is held to the same contract
/// by a test file that mirrors `backend/tests/sync/` case-for-case.
library;

import 'dart:typed_data';

import 'recovery_escrow.dart';

export 'recovery_escrow.dart' show RecoveryEscrowRecord;

/// A Member's registered public keys.
///
/// A registry row confers no authority: a Member's key is learned from its own
/// Root-signed MemberRegister in the log, and this is a bootstrap hint.
class MemberRecord {
  const MemberRecord({
    required this.memberId,
    required this.signPk,
    required this.keyId,
    this.kexPk,
    this.chained = false,
  });

  final String memberId;
  final Uint8List signPk;

  /// Server-derived: the first 8 bytes of SHA-256 over [signPk].
  final Uint8List keyId;

  /// The X25519 key, when one is registered. Null for rows predating #548;
  /// nothing reads it until #554's KeyWraps.
  final Uint8List? kexPk;

  /// The server's own view of whether a MemberRegister landed. A hint, and
  /// never an input to verification — that is what chain-gating means.
  final bool chained;
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
///
/// [code] is the server's structured `detail.code` when there was one. Assert on
/// it rather than on [detail]: the codes are the contract, the prose is not.
class SyncTransportException implements Exception {
  const SyncTransportException(this.statusCode, this.detail, {this.code});

  const SyncTransportException.unreachable(this.detail)
      : statusCode = null,
        code = null;

  final int? statusCode;
  final String detail;
  final String? code;

  bool get isUnreachable => statusCode == null;

  @override
  String toString() =>
      'SyncTransportException(${statusCode ?? 'unreachable'}'
      '${code == null ? '' : ', $code'}): $detail';
}

/// The User-credential surface: everything a Device needs *before* it holds a
/// member credential, and nothing that speaks for a Device.
abstract class UserTransport {
  /// Store this Device's public keys. Confers no authority on its own.
  Future<MemberRecord> registerMember({
    required String memberId,
    required Uint8List signPk,
    required Uint8List kexPk,
  });

  /// A bootstrap hint. Verification never reads it.
  Future<List<MemberRecord>> fetchMembers(String workspaceId);

  /// Read the passphrase-wrapped Root. Rate-limited and audited server-side;
  /// null when the slot is empty.
  Future<RecoveryEscrowRecord?> fetchRecoveryEscrow(String workspaceId);

  /// Write the escrow. The server checks the Root signature against the
  /// `root_pk` already in the slot, so this cannot overwrite someone's Root.
  Future<RecoveryEscrowRecord> putRecoveryEscrow(
    String workspaceId,
    RecoveryEscrowRecord record,
  );

  /// Ask for a single-use nonce to prove possession of [memberId]'s key.
  Future<Uint8List> requestMemberChallenge(String memberId);

  /// Exchange a signed challenge for the member-scoped transport.
  Future<SyncTransport> completeMemberChallenge({
    required String memberId,
    required Uint8List nonce,
    required Uint8List signature,
  });
}

/// The member-credential surface. Every op posted through it must name the
/// token's own Member as its author.
abstract class SyncTransport {
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

  /// One (re)subscription per listen. Events are pokes: "new seq available,
  /// run a sync from your cursor". The server sends one poke immediately on
  /// successful subscribe, and keepalives while idle (not surfaced as events).
  /// Stream error carries the close code when the server refused us (4401,
  /// 4403); error/done otherwise = connection lost. The caller owns
  /// reconnect policy.
  Stream<void> newSeqSignals(String workspaceId);
}
