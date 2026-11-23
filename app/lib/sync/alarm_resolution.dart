/// What the User decided about a standing sync condition, and which decisions
/// each condition may be given.
///
/// A condition that the User has answered is a different thing from a condition
/// that is still open. The class of a condition (`sync_condition_class.dart`)
/// says what it *is* to the User; a resolution says what the User *did about
/// it*. Neither is derived from the other: an alarm can be actionable and
/// already decided, and a decided alarm is still worth reporting — the User
/// should know it happened, they just should not be asked about it again.
///
/// **Pure.** Nothing here touches the database, the network or the clock; the
/// functions map stored codes to decisions and back. The one type this file
/// names from the database tier is the generated row, so that a caller holding
/// a row does not have to unpack it into loose arguments first.
///
/// The vocabulary of *what a condition is called* is the screens tier's
/// (`screens/sync_health/sync_health_copy.dart`). The dependency runs one way:
/// screens read a resolution, this tier never reads a sentence.
library;

import 'chain_verifier.dart';
import 'sync_condition_class.dart';
import 'sync_database.dart';

/// A decision the User recorded on an integrity alarm or on a refused op.
///
/// The three are not interchangeable. *Took upstream* says the server's chain
/// is the one to keep. *Kept ours* says this device's version is the one to
/// keep, and the work of putting it back is the app's. *Rejected
/// permanently* says the condition is never going to resolve itself and the
/// User is done with it.
enum AlarmResolution {
  tookUpstream('took_upstream'),
  keptOurs('kept_ours'),
  rejectedPermanently('rejected_permanently');

  const AlarmResolution(this.code);

  /// The stored form of this decision, as written to the `resolution` column.
  final String code;
}

/// The stored form of a decision, read back.
AlarmResolution? alarmResolutionByCodeOrNull(String code) {
  for (final resolution in AlarmResolution.values) {
    if (resolution.code == code) return resolution;
  }
  return null;
}

/// The decisions that may be recorded on an alarm of this kind.
///
/// **An exhaustive switch on purpose**, like the classification beside it: a
/// new alarm kind without a decision to offer is a compile error rather than a
/// condition that silently offers the User nothing.
///
/// The list is empty for every kind whose condition is already closed by
/// mechanism — a heal, a reordering that converged, a refusal the User has
/// nothing to decide about. Those kinds carry a filed issue instead of a
/// decision, and offering a decision there would be offering a choice between
/// two things the User cannot have.
///
/// One kind has two answers, and the kind alone cannot say which. A rollback
/// alarm is the server having lost writes it acknowledged — where *keep ours*
/// is right, and the work is reposting from the last agreed position — or the
/// server holding a position this device never wrote, which is not the same
/// accident and has no agreed position to repost from. The row tells them
/// apart: [resolutionsOfferedForAlarmRow] narrows the rollback case by
/// [IntegrityAlarmRow.repostFromAuthorSeq].
List<AlarmResolution> resolutionsForAlarm(IntegrityAlarmKind kind) =>
    switch (kind) {
      // --- the server's chain is the one to keep --------------------------
      IntegrityAlarmKind.authorChainGap => const [AlarmResolution.tookUpstream],

      // --- this device's chain is the one to keep ------------------------
      IntegrityAlarmKind.ownWritesRollback ||
      IntegrityAlarmKind.ownWritesDivergence =>
        const [AlarmResolution.keptOurs],

      // --- the condition is permanent; the User ends it -------------------
      IntegrityAlarmKind.authorChainFork ||
      IntegrityAlarmKind.prevAuthorHashMismatch ||
      IntegrityAlarmKind.authorChainRewrite ||
      IntegrityAlarmKind.duplicateOpIdDivergence ||
      IntegrityAlarmKind.signatureInvalid ||
      IntegrityAlarmKind.aeadFailure ||
      IntegrityAlarmKind.plaintextAtEncryptedEpoch ||
      IntegrityAlarmKind.noLiveGrant =>
        const [AlarmResolution.rejectedPermanently],

      // --- nothing to decide: the condition closes by mechanism -----------
      IntegrityAlarmKind.ownWriteRefusedPermanently ||
      IntegrityAlarmKind.epochKeySetUnpublishable ||
      IntegrityAlarmKind.authorStreamReordered ||
      IntegrityAlarmKind.stalePrefixServed ||
      IntegrityAlarmKind.controlChainFork ||
      IntegrityAlarmKind.authorChainSlotCollision ||
      IntegrityAlarmKind.pruneAttestationDivergence =>
        const <AlarmResolution>[],
    };

/// The decisions that may be recorded on an alarm of this stored code.
///
/// An unknown code offers nothing and throws nothing: a store written by a
/// newer build, or by a build that knew codes this one does not, must not
/// make the health query fail.
List<AlarmResolution> resolutionsForAlarmCode(String code) {
  final kind = integrityAlarmKindByCodeOrNull(code);
  if (kind == null) return const <AlarmResolution>[];
  return resolutionsForAlarm(kind);
}

/// The decisions that may be recorded on a refusal of this stored code.
///
/// A refusal only offers a decision when nothing else offers one: it does not
/// escalate to an alarm of its own, and it does not heal by itself. A refusal
/// that escalates is settled on the alarm that carries it; a self-healing
/// refusal is waiting for delivery and needs no decision. What is left is a
/// refusal that will still be there tomorrow — a codec that will not read, a
/// certificate that will not verify — which the User can end for good.
List<AlarmResolution> resolutionsForRefusalCode(String code) {
  final reason = syncRejectionReasonByCodeOrNull(code);
  if (reason == null) return const <AlarmResolution>[];
  if (syncConditionClassOfRefusal(reason) == SyncConditionClass.transient) {
    return const <AlarmResolution>[];
  }
  if (alarmForRejection(reason) != null) return const <AlarmResolution>[];
  return const [AlarmResolution.rejectedPermanently];
}

/// The decisions that may still be recorded on this alarm row.
///
/// Empty when the row has already been decided — a decided row is not offered
/// a second decision, whatever it is decided about.
///
/// Empty for the rollback alarm whose server holds a position this device
/// never wrote: there is no agreed position to repost from, so there is no
/// "keep ours" to offer. That case has no filed issue yet either (#974), so it
/// offers nothing at all until one of them lands.
List<AlarmResolution> resolutionsOfferedForAlarmRow(IntegrityAlarmRow row) {
  if (row.resolution != null) return const <AlarmResolution>[];
  if (row.kind == IntegrityAlarmKind.ownWritesRollback.code &&
      row.repostFromAuthorSeq == null) {
    return const <AlarmResolution>[];
  }
  return resolutionsForAlarmCode(row.kind);
}
