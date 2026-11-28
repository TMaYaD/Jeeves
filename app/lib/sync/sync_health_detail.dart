/// One row of the account the sync-health screen gives.
///
/// A view model over the two tables the spine persists — `integrity_alarms` and
/// `quarantined_ops` — flattened to the one shape the screen renders, because
/// the screen's grouping is by *class* and not by table: a refused envelope and
/// the accusation it raised are the same event told from either side, and the
/// user has no reason to know they live in different places.
///
/// **It carries no copy.** A row here is the stored code, the class it falls
/// under, when it happened and the decisions it may still be given; the
/// sentence the user reads and the words on the buttons are resolved in
/// `screens/sync_health/sync_health_copy.dart` from exactly those. That is what
/// keeps this file — which reads the two tables — from importing a screen.
library;

import 'alarm_resolution.dart';
import 'sync_condition_class.dart';
import 'sync_database.dart';

enum SyncConditionSource {
  /// A standing accusation: `integrity_alarms`.
  standingCondition,

  /// One refused item: `quarantined_ops`.
  refusedItem,
}

class SyncHealthCondition {
  const SyncHealthCondition({
    required this.workspaceId,
    required this.source,
    required this.code,
    required this.firstSeenAt,
    required this.lastSeenAt,
    required this.occurrenceCount,
    required this.reAdmitted,
    required this.rowId,
    this.detail = '',
    this.memberId,
    this.resolutions = const <AlarmResolution>[],
    this.resolutionInFlight = false,
  });

  final String workspaceId;
  final SyncConditionSource source;

  /// The stored `IntegrityAlarmKind.code` or `SyncRejectionReason.code`.
  ///
  /// Shown only inside a row's expandable, never in the collapsed screen: it is
  /// the string an operator needs and the one a user should never have to read.
  final String code;

  final DateTime firstSeenAt;
  final DateTime lastSeenAt;
  final int occurrenceCount;

  /// A refused item that later became valid and was applied after all.
  ///
  /// Marked rather than hidden: the difference between "arrived out of order"
  /// and "withheld and still missing" is exactly what a user reading this page
  /// is trying to establish.
  final bool reAdmitted;

  final int rowId;
  final String detail;
  final String? memberId;

  /// The decisions this condition may still be given.
  ///
  /// Empty whenever there is nothing to decide: the kind has no decision at
  /// all (it closes by mechanism), the condition has already been answered, or
  /// the row behind it is one the user cannot act on. **A condition that offers
  /// a decision is the only kind that carries a button** — there is no
  /// dismiss, and nothing is offered that the row would refuse.
  final List<AlarmResolution> resolutions;

  /// Whether a decision has been made and its work has not landed yet.
  ///
  /// The one case is *keep ours* on a rollback: the accusation is answered but
  /// the re-send has not been acknowledged, so the condition is not settled.
  /// The row says so with a progress bar, and the indicator is the blue
  /// Syncing one — never amber, which is spent on the calm state.
  final bool resolutionInFlight;
}

/// One Workspace's rows, as the screen renders them.
///
/// A pure function over what the two tables hold, so the fold the screen depends
/// on is exercised by a test reading a real store rather than only by a live
/// widget over a Drift `watch()`.
///
/// Three filters, all load-bearing:
///
/// * **Only unresolved accusations.** A resolved one is history the log keeps and
///   the screen does not re-litigate.
/// * **No self-healing refusals, released or not.** A wrap in flight is not an
///   event, and a wrap that arrived is not news about the one that was late.
/// * **No answered refusals.** A refused change the user has already refused
///   for good is a decision, not a question, and a question already answered is
///   not asked again.
///
/// The decisions a row may still be given come from the row's own kind
/// (`alarm_resolution.dart`), never from the screen: a kind that offers no
/// decision offers no button, and the row cannot be asked for one the store
/// would refuse.
///
/// [appliedRefusalRowIds] names the refused rows whose change the log has
/// since applied. Such a row is listed — it is the evidence that the change
/// arrived out of order — but it offers no decision: the change is in, and no
/// later rebuild would check a decision about it.
///
/// **Null means the set is not known yet**, and the refused rows are withheld
/// until it is: a row whose change the log has applied offers no decision, and
/// offering one for a row that is in fact applied is a decision the store
/// would refuse. The rows are withheld rather than shown without their
/// decisions, because a refusal the User can act on is worth showing and one
/// they cannot is not. An empty set means the set is known and holds nothing.
List<SyncHealthCondition> syncHealthConditionsFor({
  required String workspaceId,
  required List<IntegrityAlarmRow> alarms,
  required List<QuarantineRow> refusals,
  Set<int>? appliedRefusalRowIds = const {},
}) =>
    [
      for (final row in alarms)
        if (row.resolvedAt == null)
          SyncHealthCondition(
            workspaceId: workspaceId,
            source: SyncConditionSource.standingCondition,
            code: row.kind,
            firstSeenAt: row.firstDetectedAt,
            lastSeenAt: row.lastDetectedAt,
            occurrenceCount: row.occurrenceCount,
            reAdmitted: false,
            rowId: row.id,
            detail: row.detail,
            memberId: row.authorMemberId,
            resolutions: resolutionsOfferedForAlarmRow(row),
            resolutionInFlight: row.resolution != null && row.resolvedAt == null,
          ),
      // The refused rows are withheld while the applied set is unknown: see
      // the parameter's contract above.
      if (appliedRefusalRowIds != null)
        for (final row in refusals)
          if (classOfRefusalCode(row.reason) != SyncConditionClass.transient &&
              row.resolution == null)
            SyncHealthCondition(
              workspaceId: workspaceId,
              source: SyncConditionSource.refusedItem,
              code: row.reason,
              firstSeenAt: row.detectedAt,
              lastSeenAt: row.releasedAt ?? row.detectedAt,
              occurrenceCount: 1,
              reAdmitted: row.releasedAt != null,
              rowId: row.id,
              detail: row.detail,
              memberId: row.authorMemberId,
              // A refused change that was applied later has nothing left to
              // decide; one that is still held may be refused for good.
              resolutions: row.releasedAt == null &&
                      !appliedRefusalRowIds.contains(row.id)
                  ? resolutionsForRefusalCode(row.reason)
                  : const <AlarmResolution>[],
            ),
    ];

/// The class the screen groups a condition under.
SyncConditionClass classOfCondition(SyncHealthCondition condition) =>
    switch (condition.source) {
      SyncConditionSource.standingCondition => classOfAlarmCode(condition.code),
      SyncConditionSource.refusedItem => classOfRefusalCode(condition.code),
    };
