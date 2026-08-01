/// One row of the account the sync-health screen gives.
///
/// A view model over the two tables the spine persists — `integrity_alarms` and
/// `quarantined_ops` — flattened to the one shape the screen renders, because
/// the screen's grouping is by *class* and not by table: a refused envelope and
/// the accusation it raised are the same event told from either side, and the
/// user has no reason to know they live in different places.
library;

import '../screens/sync_health/sync_health_copy.dart';
import 'ids.dart';
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
    required this.sentence,
    required this.firstSeenAt,
    required this.lastSeenAt,
    required this.occurrenceCount,
    required this.reAdmitted,
    required this.rowId,
    this.detail = '',
    this.memberId,
  });

  final String workspaceId;
  final SyncConditionSource source;

  /// The stored `IntegrityAlarmKind.code` or `SyncRejectionReason.code`.
  ///
  /// Shown only inside a row's expandable, never in the collapsed screen: it is
  /// the string an operator needs and the one a user should never have to read.
  final String code;

  /// The one plain sentence this condition is told as.
  final String sentence;

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
}

/// One Workspace's rows, as the screen renders them.
///
/// A pure function over what the two tables hold, so the fold the screen depends
/// on is exercised by a test reading a real store rather than only by a live
/// widget over a Drift `watch()`.
///
/// Two filters, both load-bearing:
///
/// * **Only unresolved accusations.** A resolved one is history the log keeps and
///   the screen does not re-litigate.
/// * **No self-healing refusals, released or not.** A wrap in flight is not an
///   event, and a wrap that arrived is not news about the one that was late.
List<SyncHealthCondition> syncHealthConditionsFor({
  required String workspaceId,
  required List<IntegrityAlarmRow> alarms,
  required List<QuarantineRow> refusals,
}) =>
    [
      for (final row in alarms)
        if (row.resolvedAt == null)
          SyncHealthCondition(
            workspaceId: workspaceId,
            source: SyncConditionSource.standingCondition,
            code: row.kind,
            sentence: sentenceForAlarmCode(row.kind),
            firstSeenAt: row.firstDetectedAt,
            lastSeenAt: row.lastDetectedAt,
            occurrenceCount: row.occurrenceCount,
            reAdmitted: false,
            rowId: row.id,
            detail: row.detail,
            memberId: row.authorMemberId,
          ),
      for (final row in refusals)
        if (classOfRefusalCode(row.reason) != SyncConditionClass.transient)
          SyncHealthCondition(
            workspaceId: workspaceId,
            source: SyncConditionSource.refusedItem,
            code: row.reason,
            sentence: sentenceForRefusalCode(row.reason),
            firstSeenAt: row.detectedAt,
            lastSeenAt: row.releasedAt ?? row.detectedAt,
            occurrenceCount: 1,
            reAdmitted: row.releasedAt != null,
            rowId: row.id,
            detail: row.detail,
            memberId: row.authorMemberId,
          ),
    ];

/// The class the screen groups a condition under.
SyncConditionClass classOfCondition(SyncHealthCondition condition) =>
    switch (condition.source) {
      SyncConditionSource.standingCondition => classOfAlarmCode(condition.code),
      SyncConditionSource.refusedItem => classOfRefusalCode(condition.code),
    };

/// What to call one of the device's two Workspaces, in the user's own terms.
///
/// Null for an id this build does not recognise — a section with no honest label
/// shows no label at all, rather than a raw uuid.
String? syncWorkspaceLabelFor(String workspaceId, String userId) {
  if (workspaceId == defaultWorkspaceId(userId)) return 'TASKS AND LISTS';
  if (workspaceId == userPreferencesWorkspaceId(userId)) return 'SETTINGS';
  return null;
}
