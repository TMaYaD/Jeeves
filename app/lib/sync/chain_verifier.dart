/// Per-author chain enforcement, and the vocabulary of what it accuses.
///
/// The walking skeleton already emitted truthful `author_seq` and
/// `prev_author_hash` on every envelope and kept every received envelope byte
/// for byte. This is the verification all of that plumbing was laid for: a
/// server that drops, reorders, rewinds or substitutes an author's ops cannot do
/// it invisibly, because each op names its own position in its author's chain
/// and the hash of the op before it.
///
/// Two vocabularies live here and they are deliberately not 1:1:
///
/// * a **quarantine reason** (`SyncRejectionReason`, in `envelope.dart`) answers
///   *why was this envelope refused* — one row per refused envelope;
/// * an **[IntegrityAlarmKind]** answers *what is the server or author accused
///   of* — one row per standing accusation, however many envelopes it covers.
///
/// One gap alarm can cover a hundred refused successors, and
/// `own_writes_rollback` has no received envelope to refuse at all: it is
/// detected when the server rejects *our* POST. Collapsing the two would lose
/// one of those two facts.
///
/// [chainVerdict] is pure over what the caller already read, so the whole D5
/// matrix is unit-testable with no database and no clock. The I/O — deriving the
/// head, the release scan's fixpoint loop, raising alarms — lives in
/// `sync_client.dart`, next to the receive pipeline it is part of.
library;

import 'dart:typed_data';

import 'envelope.dart';

/// What the server or an author stands accused of.
///
/// The `code` strings are the contract with the persisted `integrity_alarms`
/// rows and with anything that renders them; they are client-only — no envelope
/// field, no route, and no golden vector carries one, because a chain rule is
/// stateful *receiver* policy rather than a per-envelope codec rule.
enum IntegrityAlarmKind {
  /// A received `author_seq` is beyond the verified head + 1: ops are missing.
  authorChainGap('author_chain_gap'),

  /// Right position, wrong linkage — the op at head + 1 does not name the head.
  prevAuthorHashMismatch('prev_author_hash_mismatch'),

  /// A position the chain already holds, served with different bytes.
  authorChainRewrite('author_chain_rewrite'),

  /// Gap successors became chain-valid as their predecessors arrived. Raised
  /// whenever the release scan re-admitted anything at all; the *gap* alarm is
  /// resolved only once no unreleased gap row is left for the author, so while
  /// one stands the gap alarm stands beside this one.
  authorStreamReordered('author_stream_reordered'),

  /// Two incompatible continuations claim the same position. Either the missing
  /// predecessor arrived and a successor does not chain to it, or several
  /// byte-different successors all chain to it and only one could be released.
  authorChainFork('author_chain_fork'),

  /// A pull returned an op at or below the cursor we asked past. `since` is a
  /// pure client parameter, so an honest server cannot do this.
  stalePrefixServed('stale_prefix_served'),

  /// The server refused our own POST at a position it had already acknowledged.
  ownWritesRollback('own_writes_rollback'),

  /// An envelope this device authored came back with different bytes than the
  /// outbox row it was signed into.
  ownWritesDivergence('own_writes_divergence'),

  /// A second envelope under the same `(author, op_id)` with different bytes:
  /// dedupe by op id must not be able to mask a substitution (review F13).
  duplicateOpIdDivergence('duplicate_op_id_divergence'),

  /// A signature that does not verify. Per the spec this is an alarm surfaced to
  /// the user and never merely a skipped row — the rule AEAD failure inherits
  /// when #554 lands.
  signatureInvalid('signature_invalid'),

  /// Two control ops named the same predecessor. The tie-break picked one branch
  /// and quarantined the other; content was re-reduced under the corrected grants
  /// view, because a resolved control fork can change which content ops were
  /// authorized and convergence of the grants view alone is not convergence.
  controlChainFork('control_chain_fork'),

  /// A content op whose author held no Grant permitting its `op_class` at the
  /// op's own seq. Raised independently of anything the server did — clients
  /// never read server grant rows.
  noLiveGrant('no_live_grant'),

  /// An append found the slot it claims already taken.
  ///
  /// [chainVerdict] cannot produce this — it refuses a *chain* position the log
  /// already holds — but the *transport* can: a server that spends one `seq` on
  /// two different chain-valid ops collides on the log's primary key, and the
  /// append refuses rather than overwrites, because the log is evidence and
  /// evidence is not edited. The op is skipped and this accusation raised, so one
  /// poisoned position cannot stall the rest of a pull.
  authorChainSlotCollision('author_chain_slot_collision');

  const IntegrityAlarmKind(this.code);

  /// The stable machine code written into the alarm row.
  final String code;

  static IntegrityAlarmKind byCode(String code) =>
      IntegrityAlarmKind.values.firstWhere((kind) => kind.code == code);
}

/// One author's verified head: the highest position of theirs the log holds, and
/// the hash of the envelope at it.
///
/// Derived from `op_log` at read time and never stored. A persisted head would
/// be a cache of the log by definition — free to go stale, and (per the naming
/// rule) obliged to say so in its name. The log is the evidence; the head is a
/// question asked of it.
typedef AuthorChainHead = ({int authorSeq, Uint8List envelopeHash});

/// A position attested by a verified prune op, standing in for history that was
/// compacted away (#555).
///
/// Dormant: nothing supplies one yet. It is here because the reconciliation rule
/// it serves — *a chain gap covered by a verified prune op is not an alarm* — has
/// to be a rule the verdict already knows about, or every honest bootstrap after
/// a compaction is an alarm storm. When supplied it substitutes for an **absent**
/// head; a derived head always wins, because the log outranks an attestation
/// about the log.
typedef VerifiedChainFloor = ({int seq, Uint8List envelopeHash});

/// One op's stored twin, as the caller read it out of `op_log`.
typedef StoredChainOp = ({int authorSeq, Uint8List envelope});

/// What the chain rules say about one received op.
enum ChainOutcome {
  /// Chain-valid: continue the receive pipeline.
  accept,

  /// A position already held, byte-identical. Not an accusation: a server may
  /// legitimately re-serve after a cursor reset, and this is also the normal
  /// shape of a device's own op echoing back. Advance past it, re-apply nothing.
  idempotentSkip,

  /// Refused. [ChainVerdict.rejection] and [ChainVerdict.alarm] say which.
  refuse,
}

/// The verdict on one received op: whether to continue, and what to record.
class ChainVerdict {
  const ChainVerdict.accept()
      : outcome = ChainOutcome.accept,
        rejection = null,
        alarm = null;

  const ChainVerdict.idempotentSkip()
      : outcome = ChainOutcome.idempotentSkip,
        rejection = null,
        alarm = null;

  const ChainVerdict.refuse(SyncRejection this.rejection, IntegrityAlarmKind this.alarm)
      : outcome = ChainOutcome.refuse;

  final ChainOutcome outcome;

  /// The per-op refusal to quarantine under. Null unless [outcome] is
  /// [ChainOutcome.refuse].
  final SyncRejection? rejection;

  /// The standing accusation to raise. Null unless [outcome] is
  /// [ChainOutcome.refuse].
  final IntegrityAlarmKind? alarm;

  bool get isRefusal => outcome == ChainOutcome.refuse;
}

final Uint8List _zeroPrevAuthorHash = Uint8List(prevAuthorHashBytes);

/// The chain rules, over one received op and what the log already holds.
///
/// [storedAtAuthorSeq] is the `op_log` row at `header.authorSeq` for this
/// author, if any; [storedUnderOpId] is the row under `(author, op_id)`, if any.
/// [head] is the author's derived head, and [verifiedFloor] the dormant #555
/// substitute for an absent one.
///
/// No latching anywhere: a refusal never moves the head, so the author's stream
/// is judged against the last position this device actually verified rather than
/// against whatever the server last claimed.
ChainVerdict chainVerdict({
  required OpHeader header,
  required Uint8List envelope,
  AuthorChainHead? head,
  StoredChainOp? storedAtAuthorSeq,
  StoredChainOp? storedUnderOpId,
  VerifiedChainFloor? verifiedFloor,
}) {
  // Checked first and independently of position: an op id the log already holds
  // under a *different* position, or under the same one with different bytes, is
  // a substitution wearing a known name. Deduping by op id before comparing
  // bytes is exactly how that gets missed (review F13).
  if (storedUnderOpId != null &&
      (storedUnderOpId.authorSeq != header.authorSeq ||
          !sameBytes(storedUnderOpId.envelope, envelope))) {
    return ChainVerdict.refuse(
      SyncRejection(
        SyncRejectionReason.duplicateOpIdDivergence,
        'op_id ${header.opId} is already logged at author_seq '
        '${storedUnderOpId.authorSeq} with different bytes',
      ),
      IntegrityAlarmKind.duplicateOpIdDivergence,
    );
  }

  // A supplied floor substitutes for an absent head, so a post-prune bootstrap
  // never falls into the zero-hash branch below: seq 0 with the zero hash is
  // only what "this author's chain starts here" means when nothing at all is
  // known about it.
  final headSeq = head?.authorSeq ?? verifiedFloor?.seq ?? 0;
  final headHash = head?.envelopeHash ?? verifiedFloor?.envelopeHash ?? _zeroPrevAuthorHash;

  if (header.authorSeq == headSeq + 1) {
    if (sameBytes(header.prevAuthorHash, headHash)) return const ChainVerdict.accept();
    return ChainVerdict.refuse(
      SyncRejection(
        SyncRejectionReason.prevAuthorHashMismatch,
        'author_seq ${header.authorSeq} does not name the envelope at $headSeq',
      ),
      IntegrityAlarmKind.prevAuthorHashMismatch,
    );
  }

  if (header.authorSeq > headSeq + 1) {
    return ChainVerdict.refuse(
      SyncRejection(
        SyncRejectionReason.authorChainGap,
        'author_seq ${header.authorSeq} skips ahead of head $headSeq',
      ),
      IntegrityAlarmKind.authorChainGap,
    );
  }

  // At or below the head. Identical bytes are the honest re-serve; anything else
  // claims a slot this device has already verified something different into —
  // including a header claiming seq 0, which no author ever writes.
  if (storedAtAuthorSeq != null && sameBytes(storedAtAuthorSeq.envelope, envelope)) {
    return const ChainVerdict.idempotentSkip();
  }
  return ChainVerdict.refuse(
    SyncRejection(
      SyncRejectionReason.authorChainRewrite,
      'author_seq ${header.authorSeq} is at or below head $headSeq and differs '
      'from what this device holds there',
    ),
    IntegrityAlarmKind.authorChainRewrite,
  );
}

/// The alarm a per-op refusal escalates to, or null when the refusal stands
/// alone.
///
/// Only the accusations the spec names are here. A codec-level refusal — an
/// unknown suite, a bad padding byte — is a refused envelope and nothing more;
/// a signature that does not verify is an alarm, because the spec says signature
/// failure is surfaced to the user and never merely a skipped row.
IntegrityAlarmKind? alarmForRejection(SyncRejectionReason reason) => switch (reason) {
      SyncRejectionReason.badSignature => IntegrityAlarmKind.signatureInvalid,
      SyncRejectionReason.authorChainGap => IntegrityAlarmKind.authorChainGap,
      SyncRejectionReason.prevAuthorHashMismatch =>
        IntegrityAlarmKind.prevAuthorHashMismatch,
      SyncRejectionReason.authorChainRewrite => IntegrityAlarmKind.authorChainRewrite,
      SyncRejectionReason.duplicateOpIdDivergence =>
        IntegrityAlarmKind.duplicateOpIdDivergence,
      SyncRejectionReason.ownWritesDivergence => IntegrityAlarmKind.ownWritesDivergence,
      SyncRejectionReason.staleReplayedOp => IntegrityAlarmKind.stalePrefixServed,
      SyncRejectionReason.controlChainFork => IntegrityAlarmKind.controlChainFork,
      // An op the server should never have accepted: it holds the same grants
      // index the verdict is about, so serving one is a claim worth surfacing.
      SyncRejectionReason.noLiveGrant => IntegrityAlarmKind.noLiveGrant,
      _ => null,
    };
