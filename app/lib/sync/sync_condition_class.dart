/// What a standing sync condition *is to the User* — the classification that
/// decides whether the indicator turns red.
///
/// Until this landed, every unresolved integrity alarm and every unreleased
/// refusal drove `SyncHealth.degraded`, so a device painted itself red for
/// conditions it had handled perfectly: a forged envelope it correctly refused,
/// a reorder that healed, a KeyWrap that had simply not arrived yet. Nothing can
/// clear most of those, so the red was also permanent. A red indicator the User
/// can do nothing about is what trains them to ignore red indicators.
///
/// The class is **a property of the kind, fixed at design time** — never a state
/// a gesture can set, which is what keeps this from being dismissal wearing a
/// different hat. It is computed from the stored `kind` / `reason` string and
/// persisted nowhere, so there is no column that can disagree with the code.
///
/// **Every classification of a stored code lives here, and no user-facing word
/// does.** A class is domain state — the health query reads it, the indicator's
/// colour follows from it, and the compaction gate sits beside it — so it belongs
/// in the tier that owns the two tables. What a condition is *called* is the
/// screens tier's (`screens/sync_health/sync_health_copy.dart`), and the
/// dependency runs one way: screens read the class, the sync tier never reads a
/// sentence.
///
/// See ADR-0044.
library;

import 'chain_verifier.dart';
import 'envelope.dart';

enum SyncConditionClass {
  /// Something of the User's is stuck or lost and no mechanism here fixes it.
  /// The only class that drives the error indicator. Four alarm kinds.
  ///
  /// It does **not** mean "we offer a fix here" — all four are reported as
  /// statements, because their mechanisms live elsewhere. What it buys is
  /// honesty in the indicator: these four are the cases where something of the
  /// User's is genuinely stuck, so these four are the only ones that turn it red.
  actionable,

  /// The app already did the right thing and nothing is at risk. Worth reading;
  /// never an error. Fourteen alarm kinds, and every refusal reason that is not
  /// a delivery gap.
  reported,

  /// Waiting on delivery, heals by itself. Neither an error nor worth
  /// interrupting for, and surfaced nowhere. Five refusal reasons.
  transient,
}

/// The class of one integrity-alarm kind.
///
/// An **exhaustive switch on purpose**: adding a kind without deciding what it
/// is to the User is a compile error rather than a new red icon nobody chose.
SyncConditionClass syncConditionClassOf(IntegrityAlarmKind kind) => switch (kind) {
      // --- actionable: something of the User's is stuck or lost ------------
      IntegrityAlarmKind.authorChainGap ||
      IntegrityAlarmKind.ownWritesRollback ||
      IntegrityAlarmKind.ownWriteRefusedPermanently ||
      IntegrityAlarmKind.epochKeySetUnpublishable =>
        SyncConditionClass.actionable,

      // --- reported: the app handled it and nothing is at risk -------------
      IntegrityAlarmKind.ownWritesDivergence ||
      IntegrityAlarmKind.authorStreamReordered ||
      IntegrityAlarmKind.stalePrefixServed ||
      IntegrityAlarmKind.controlChainFork ||
      IntegrityAlarmKind.authorChainSlotCollision ||
      IntegrityAlarmKind.pruneAttestationDivergence ||
      IntegrityAlarmKind.prevAuthorHashMismatch ||
      IntegrityAlarmKind.authorChainRewrite ||
      IntegrityAlarmKind.authorChainFork ||
      IntegrityAlarmKind.duplicateOpIdDivergence ||
      IntegrityAlarmKind.signatureInvalid ||
      IntegrityAlarmKind.aeadFailure ||
      IntegrityAlarmKind.plaintextAtEncryptedEpoch ||
      IntegrityAlarmKind.noLiveGrant =>
        SyncConditionClass.reported,
    };

/// The class of one refusal reason.
///
/// Only the five self-healing reasons are named; **everything else defaults to
/// [SyncConditionClass.reported]**, and that direction is deliberate. A refusal
/// no longer drives the error indicator at all, so the cost of the default is a
/// row on a screen rather than a red icon — erring toward telling the User is
/// the safe error, and a new reason silently treated as self-healing would not
/// be. `sync_condition_class_test.dart` pins the five, so the set cannot drift
/// from the health query that reads it.
SyncConditionClass syncConditionClassOfRefusal(SyncRejectionReason reason) =>
    switch (reason) {
      // A wrap or an epoch that has not arrived yet accuses nobody and heals on
      // delivery — see the doc comments on these members in `envelope.dart`.
      SyncRejectionReason.missingEpochKey ||
      SyncRejectionReason.keyEpochUnknown ||
      SyncRejectionReason.keyEpochStale ||
      SyncRejectionReason.keyEpochBelowFloor ||
      SyncRejectionReason.unwrappableGrant =>
        SyncConditionClass.transient,
      _ => SyncConditionClass.reported,
    };

/// The kinds that turn the indicator red, as their stored codes.
///
/// Derived from the classification rather than written out, so the health query
/// and [syncConditionClassOf] cannot drift apart.
final List<String> actionableAlarmCodes = [
  for (final kind in IntegrityAlarmKind.values)
    if (syncConditionClassOf(kind) == SyncConditionClass.actionable) kind.code,
];

/// The refusal reasons that are surfaced nowhere, as their stored codes.
final List<String> transientRefusalCodes = [
  for (final reason in SyncRejectionReason.values)
    if (syncConditionClassOfRefusal(reason) == SyncConditionClass.transient)
      reason.code,
];

/// [IntegrityAlarmKind.byCode] without the throw.
///
/// The stored string is the contract, and a store written by a newer build can
/// hold a code this one has never heard of. `byCode` is a bare `firstWhere` with
/// no `orElse`, so reading such a row through it crashes the reader; every
/// user-facing path goes through this instead and renders an unknown code as a
/// row rather than as a stack trace.
IntegrityAlarmKind? integrityAlarmKindByCodeOrNull(String code) {
  for (final kind in IntegrityAlarmKind.values) {
    if (kind.code == code) return kind;
  }
  return null;
}

/// [SyncRejectionReason] from its stored code, or null for an unknown one.
SyncRejectionReason? syncRejectionReasonByCodeOrNull(String code) {
  for (final reason in SyncRejectionReason.values) {
    if (reason.code == code) return reason;
  }
  return null;
}

/// The class of a stored alarm code — the screen's grouping, and the indicator's.
///
/// An unrecognised code is [SyncConditionClass.reported]: a code we cannot
/// classify has, by definition, no evidence behind it that anything of the
/// user's is stuck, so calling it an error would be a claim we cannot support.
SyncConditionClass classOfAlarmCode(String code) {
  final kind = integrityAlarmKindByCodeOrNull(code);
  return kind == null ? SyncConditionClass.reported : syncConditionClassOf(kind);
}

/// The class of a stored refusal reason. An unrecognised one is reported, for
/// the same reason an unrecognised alarm code is.
SyncConditionClass classOfRefusalCode(String code) {
  final reason = syncRejectionReasonByCodeOrNull(code);
  return reason == null
      ? SyncConditionClass.reported
      : syncConditionClassOfRefusal(reason);
}
