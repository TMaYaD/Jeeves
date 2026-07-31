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
/// The vocabulary reaches once further still. `epoch_key_set_unpublishable`
/// accuses **nobody**: it is a standing *local* condition that will never heal
/// itself — this device holds a prepared KeyWrap set for an epoch it can provably
/// never publish — and the server behaved correctly in refusing it. A reader who
/// assumes every row names a culprit would misread it.
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

  /// An op this device authored that the server will never accept: our own POST
  /// was refused under a code no retry can change, so the queue behind it cannot
  /// drain (#647 owns the drain; this only names the condition).
  ///
  /// The third of the own-writes family, and detected the same way the first two
  /// are — the server rejecting *our* POST — so it carries `authorMemberId` the
  /// way [ownWritesRollback] does. **Workspace-scoped and epoch-agnostic**: the
  /// flush is one call per Workspace, so a refusal is not attributable to any one
  /// pending rotation and must never terminalise one.
  ownWriteRefusedPermanently('own_write_refused_permanently'),

  /// A prepared EpochKeySet this device holds for an epoch it can provably never
  /// publish: the resume PUT was refused under a code no retry can change.
  ///
  /// Accuses nobody — see the library header. The prepared bytes are **retained**
  /// on this device (ADR-0040) and the record is simply no longer resumed, so this
  /// stands until a recovery path or a dismissal (#575) clears it. There is no
  /// heal, so nothing resolves it.
  epochKeySetUnpublishable('epoch_key_set_unpublishable'),

  /// A second envelope under the same `(author, op_id)` with different bytes:
  /// dedupe by op id must not be able to mask a substitution (review F13).
  duplicateOpIdDivergence('duplicate_op_id_divergence'),

  /// A signature that does not verify. Per the spec this is an alarm surfaced to
  /// the user and never merely a skipped row — the rule [aeadFailure] inherits.
  signatureInvalid('signature_invalid'),

  /// An `aead_v1` body that did not authenticate under an epoch key this device
  /// **holds**. The normative rule from the proposal, and #554's AC-5: AEAD failure
  /// is an alarm, never a skipped row.
  ///
  /// Distinct from a missing key, which raises no accusation: not holding the key
  /// for an epoch is a delivery gap that heals when the wrap arrives, while bytes
  /// that fail under a key we do hold mean the ciphertext, the header or the key is
  /// not what the author signed. The codec cannot say which — the header is the AAD
  /// — so the accusation is the failure itself rather than a guess at its cause.
  aeadFailure('aead_failure'),

  /// A *content* op at suite `plaintext_v1` whose `key_epoch` this device holds a
  /// key for. The one-way upgrade, enforced at the read boundary.
  ///
  /// An accusation and not merely a refusal: once an epoch is keyed, every content
  /// op at it is encrypted, so a plaintext one is either a coerced author or a
  /// server replaying pre-turn-on bytes at a keyed epoch. Pre-turn-on history at
  /// *earlier*, unkeyed epochs stays readable, which is what keeps turn-on
  /// non-destructive.
  plaintextAtEncryptedEpoch('plaintext_at_encrypted_epoch'),

  /// Two control ops named the same predecessor. The tie-break picked one branch
  /// and quarantined the other; content was re-reduced under the corrected grants
  /// view, because a resolved control fork can change which content ops were
  /// authorized and convergence of the grants view alone is not convergence.
  controlChainFork('control_chain_fork'),

  /// A content op whose author held no Grant permitting its `op_class` at the
  /// op's own seq. Raised independently of anything the server did — clients
  /// never read server grant rows.
  noLiveGrant('no_live_grant'),

  /// A prune's attestation and this device's own evidence disagree about the bytes
  /// at one chain position.
  ///
  /// Both bear real signatures — a gap-reason quarantine row exists only after
  /// `verifyEnvelope` passed, and an attestation travels inside a signed prune — so
  /// either the author forked its own chain or the compactor attested a
  /// fabrication. The codec cannot say which, so the accusation is the disagreement
  /// itself rather than a guess at its cause.
  ///
  /// **Never a heal.** A device holding the originals is the only party that can
  /// catch a lying compactor; a fresh device necessarily trusts the compactor's
  /// signature plus the server's POST-time cross-check, which is what the
  /// most-trusted `compactor` role means. Where this fires the claimant stays
  /// unreleased, which leaves the gap alarm standing for that author until #575
  /// lands its reclassification — inherited behaviour, not new debt.
  pruneAttestationDivergence('prune_attestation_divergence'),

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

/// The highest position of one author's chain this device can *account for*,
/// counting positions a verified prune op attested as well as ones the log holds
/// (#555).
///
/// The reconciliation rule it serves — *a chain gap covered by a verified prune op
/// is not an alarm* — has to be a rule the verdict knows about, or every honest
/// bootstrap after a compaction is an alarm storm.
///
/// **The floor wins when it is above the derived head**, which is the one deliberate
/// change #555 makes to shipped verification logic. Entity-level compaction punches
/// holes *inside* an author's chain rather than truncating a prefix, so a device may
/// hold positions 1-2 and need to verify position 53 across attested holes; a rule
/// that always preferred the derived head could never bridge them. It is sound
/// because the caller only ever supplies a floor walked contiguously forward from
/// the real head, filling each step from the log or from a per-position, hash-linked
/// attestation — there is no gap in it to hide anything in. Below the head the floor
/// is ignored, because there the log is the better evidence.
typedef VerifiedChainFloor = ({int seq, Uint8List envelopeHash});

/// One op's stored twin, as the caller read it out of `op_log`.
typedef StoredChainOp = ({int authorSeq, Uint8List envelope});

/// What a prune attested at the position an arriving op claims, when the log holds
/// nothing there (#555).
///
/// The arrival order opposite to the ordinary bootstrap: attestations first, the
/// superseded envelope re-served later. Supplying it is what lets the verdict tell
/// a chatty server re-offering pruned bytes from a server offering *different*
/// bytes at a position it claims were removed.
typedef PrunedPositionAttestation = ({int authorSeq, Uint8List envelopeHash});

/// What the chain rules say about one received op.
enum ChainOutcome {
  /// Chain-valid: continue the receive pipeline.
  accept,

  /// A position already held, byte-identical. Not an accusation: a server may
  /// legitimately re-serve after a cursor reset, and this is also the normal
  /// shape of a device's own op echoing back. Advance past it, re-apply nothing.
  idempotentSkip,

  /// A position a verified prune attested, served with exactly the bytes it
  /// attested (#555).
  ///
  /// Treated like [idempotentSkip] — no log row, no quarantine, no accusation. A
  /// pruned original re-served is evidence of nothing but a chatty server, and if
  /// the *serving* was itself illegitimate the stale-prefix accusation already
  /// covers it. Distinct from [idempotentSkip] because there is no stored op to
  /// compare against: the comparison is against an attestation, which is a
  /// different claim and worth naming.
  supersededByPrune,

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

  const ChainVerdict.supersededByPrune()
      : outcome = ChainOutcome.supersededByPrune,
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
/// [head] is the author's derived head, [verifiedFloor] the bridged position
/// attestations account for, and [storedAttestation] what a prune attested at the
/// arriving op's own position when the log holds nothing there.
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
  PrunedPositionAttestation? storedAttestation,
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

  // The **effective** head: the floor when it reaches higher than the log does,
  // and the derived head otherwise. A supplied floor is walked contiguously
  // forward from the real head, so above the head it accounts for every skipped
  // position individually and hash-linked — see [VerifiedChainFloor]. Absent both,
  // seq 0 with the zero hash is what "this author's chain starts here" means.
  final floor = verifiedFloor;
  final derivedHeadSeq = head?.authorSeq ?? 0;
  final bridged = floor != null && floor.seq > derivedHeadSeq;
  final headSeq = bridged ? floor.seq : derivedHeadSeq;
  final headHash = bridged
      ? floor.envelopeHash
      : (head?.envelopeHash ?? _zeroPrevAuthorHash);

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
  // Nothing in the log here, but a prune said what used to be. Matching bytes are
  // a pruned original re-served; different bytes at a position the compactor
  // claimed to have removed are the forged-claimant shape, and both signatures are
  // real, so it is an accusation rather than a refusal on its own.
  if (storedAtAuthorSeq == null &&
      storedAttestation != null &&
      storedAttestation.authorSeq == header.authorSeq) {
    if (sameBytes(storedAttestation.envelopeHash, envelopeHash(envelope))) {
      return const ChainVerdict.supersededByPrune();
    }
    return ChainVerdict.refuse(
      SyncRejection(
        SyncRejectionReason.pruneAttestationDivergence,
        'author_seq ${header.authorSeq} was served with bytes a verified prune '
        'attested differently',
      ),
      IntegrityAlarmKind.pruneAttestationDivergence,
    );
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
///
/// The two encryption refusals that escalate do so for the same reason, and the one
/// that does not is [SyncRejectionReason.missingEpochKey]: a wrap that has not
/// arrived yet accuses nobody.
IntegrityAlarmKind? alarmForRejection(SyncRejectionReason reason) => switch (reason) {
      SyncRejectionReason.badSignature => IntegrityAlarmKind.signatureInvalid,
      SyncRejectionReason.aeadFailure => IntegrityAlarmKind.aeadFailure,
      SyncRejectionReason.plaintextAtEncryptedEpoch =>
        IntegrityAlarmKind.plaintextAtEncryptedEpoch,
      SyncRejectionReason.authorChainGap => IntegrityAlarmKind.authorChainGap,
      SyncRejectionReason.prevAuthorHashMismatch =>
        IntegrityAlarmKind.prevAuthorHashMismatch,
      SyncRejectionReason.authorChainRewrite => IntegrityAlarmKind.authorChainRewrite,
      SyncRejectionReason.duplicateOpIdDivergence =>
        IntegrityAlarmKind.duplicateOpIdDivergence,
      SyncRejectionReason.ownWritesDivergence => IntegrityAlarmKind.ownWritesDivergence,
      SyncRejectionReason.staleReplayedOp => IntegrityAlarmKind.stalePrefixServed,
      SyncRejectionReason.controlChainFork => IntegrityAlarmKind.controlChainFork,
      SyncRejectionReason.pruneAttestationDivergence =>
        IntegrityAlarmKind.pruneAttestationDivergence,
      // An op the server should never have accepted: it holds the same grants
      // index the verdict is about, so serving one is a claim worth surfacing.
      SyncRejectionReason.noLiveGrant => IntegrityAlarmKind.noLiveGrant,
      _ => null,
    };
