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

import 'key_wraps.dart';
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

/// The structured `detail.code` a `POST /w/{w}/ops` chain conflict carries.
const String authorChainConflictCode = 'author_chain_conflict';

/// Ops one `POST /w/{w}/ops` may carry, mirroring the server's
/// `MAX_OPS_PER_BATCH`.
///
/// Chunking is the **caller's** contract, not the transport's: a batch appends
/// in one server transaction, so splitting it is a decision about how much
/// history to commit at a time and only the caller knows the chain order the
/// chunks have to preserve. The limit is exported so both sides agree on one
/// number instead of a client cap drifting from the server's — a device that
/// authored more than this offline would otherwise re-POST the same oversized
/// batch for ever, refused with 413 `batch_too_large`, and never drain the queue
/// it exists for. `SyncClient.flushOutbox` is the caller that honours it.
const int maxOpsPerBatch = 1000;

/// One stored KeyWrap, as `GET /w/{w}/keywraps/me` serves it.
///
/// The wrap is opaque to the server and to every Member but the one it names: the
/// `info` binding covers the Workspace, the epoch, the member and the key id, so a
/// row delivered into the wrong slot fails to authenticate rather than opening.
class KeyWrapRecord {
  const KeyWrapRecord({
    required this.epoch,
    required this.memberId,
    required this.kexKeyId,
    required this.wrap,
  });

  final int epoch;
  final String memberId;

  /// The server-derived 8-byte id of the KEX key this was sealed to. Carried so a
  /// device that has rotated its KEX key can tell which of its keys opens the wrap.
  final Uint8List kexKeyId;
  final Uint8List wrap;
}

/// One epoch's escrow wrap, as `GET /w/{w}/epoch-keys` serves it.
///
/// Useless without `master_wrap_key`, which exists only inside the recovery escrow
/// blob behind Argon2id and the passphrase. That is what makes a fresh device's
/// bootstrap work with no second device online.
class EpochKeyRecord {
  const EpochKeyRecord({
    required this.epoch,
    required this.escrowWrap,
    required this.keyWrapDigest,
  });

  final int epoch;
  final Uint8List escrowWrap;

  /// The commitment the epoch was published under — the `rotate` op's own digest
  /// for every epoch above 0, and the founding client's for epoch 0.
  final Uint8List keyWrapDigest;
}

/// The structured `detail.code` a wraps PUT gets when nothing has committed to a
/// digest for the epoch yet.
///
/// The ordering the ceremony has to get right: author the `rotate`, let it land,
/// then PUT. A caller that sees this has raced its own rotate.
const String rotateNotMaterialisedCode = 'rotate_not_materialised';

/// The structured `detail.code` a wraps PUT gets when the set does not hash to the
/// digest the log committed to.
const String keyWrapDigestMismatchCode = 'keywrap_digest_mismatch';

/// A `workspace_genesis` posted into a Workspace that already has one.
///
/// A 409 that is **not** an accusation and not a wedge: genesis authorship is
/// log-state-conditioned, so two Root-holding devices may both observe an empty
/// log and both author one. Losing is a legal outcome of a legal race, and the
/// loser's move is to drop the queued genesis and claim its place with a
/// `member_register` instead (see `SyncClient.flushOutbox`).
const String genesisNotFirstCode = 'genesis_not_first';

/// The server disagrees with our own acknowledged history.
///
/// Single-writer-per-member means this is never a co-author's fault: either the
/// server rolled our writes back, or this device came back from an older local
/// backup, or something is authoring under our key. The client cannot tell those
/// apart from one 409, which is exactly why the fields are parsed out rather than
/// the prose read: `SyncClient` needs to know *which* position the server
/// expected before it can say anything at all.
///
/// Every field is nullable because the race-retry path on the server resolves a
/// raced insert without being able to attribute it to one op in the batch. An
/// absent [expectedAuthorSeq] is the "no verdict" case: an ordinary transient
/// conflict, not evidence of a rollback.
class AuthorChainConflictException extends SyncTransportException {
  const AuthorChainConflictException(
    String detail, {
    this.opIndex,
    this.submittedAuthorSeq,
    this.expectedAuthorSeq,
  }) : super(409, detail, code: authorChainConflictCode);

  /// Which op of the posted batch the server refused.
  final int? opIndex;

  /// The `author_seq` we posted at that index.
  final int? submittedAuthorSeq;

  /// The `author_seq` the server believes comes next for this author.
  final int? expectedAuthorSeq;

  @override
  String toString() => 'AuthorChainConflictException(index: $opIndex, '
      'author_seq: $submittedAuthorSeq, expected: $expectedAuthorSeq): $detail';
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
///
/// **There is no members-registry read here, and that is not an omission.** The
/// server serves `GET /w/{w}/members` behind this credential, but no client
/// calls it: a Member's key is learned only from a MemberRegister the device
/// verified itself, and `MemberDirectory.rememberChained` takes a parsed
/// certificate precisely so there is no way to feed it something the server
/// merely asserted. The registry is a bootstrap hint that verification never
/// reads (ADR-0028 — the server's tables are "authoritative for nobody"), so a
/// client method for it would be an unused seam whose only effect would be to
/// suggest the directory can be populated over HTTP. If a future slice does need
/// the read, it belongs on *this* interface and not on [UserTransport]: the
/// route requires an unrevoked member JWT.
abstract class SyncTransport {
  /// Append in order, in one transaction. Idempotent by author-namespaced op id.
  Future<List<OpAppendResult>> postOps(
    String workspaceId,
    List<Uint8List> envelopes,
  );

  /// `since` is a pure client parameter — no server-side cursor exists (F17).
  ///
  /// [includeCompacted] drops the server's soft-delete filter and serves superseded
  /// rows too — the **history view** (#555). Defaulted false and additive, so the
  /// sync path is exactly what it was: a compacted row is hidden from *sync* so a
  /// fresh device need not replay it, and the User is still owed it on request. The
  /// history read is a read, never fed through the receive pipeline.
  Future<PullPage> pullOps(
    String workspaceId, {
    required int since,
    required int limit,
    bool includeCompacted = false,
  });

  /// Upload the **whole** wrap set for one epoch. Owner only, digest-gated.
  ///
  /// Whole-set and never incremental, because the digest commits to the set: a
  /// partial upload could not be checked against it, and accepting one would restore
  /// the very curation power the digest exists to remove.
  ///
  /// [keyWrapDigest] is required for epoch 0 — the one epoch with no `rotate`
  /// behind it, so its commitment arrives in the body — and ignored above it, where
  /// the signed `rotate` op is the authority on what the digest is.
  ///
  /// Returns this Member's own wraps after the write, which is what the enrolment
  /// path needs next anyway.
  Future<List<KeyWrapRecord>> putKeyWraps(
    String workspaceId, {
    required int epoch,
    required List<MemberKeyWrap> wraps,
    required Uint8List escrowWrap,
    Uint8List? keyWrapDigest,
  });

  /// This Member's wraps across **every** epoch it has been given one for.
  ///
  /// Not parameterised by member, so there is no id to get wrong: the route is
  /// scoped to the calling credential. All epochs, because content authored at any
  /// past epoch may still have to be read.
  Future<List<KeyWrapRecord>> fetchMyKeyWraps(String workspaceId);

  /// Every epoch's escrow wrap. Epochs whose wraps have not arrived are omitted —
  /// that window is an epoch nobody can read yet, not a wrap that fails to open.
  Future<List<EpochKeyRecord>> fetchEpochKeys(String workspaceId);

  /// One subscription per call: the returned stream is single-subscription and
  /// spent once cancelled, so reconnecting means calling this again rather than
  /// re-listening. Events are pokes: "new seq available, run a sync from your
  /// cursor". The server sends one poke immediately on successful subscribe, and
  /// keepalives while idle (not surfaced as events). Stream error carries the
  /// close code when the server refused us (4401, 4403); error/done otherwise =
  /// connection lost. The caller owns reconnect policy.
  Stream<void> newSeqSignals(String workspaceId);
}
