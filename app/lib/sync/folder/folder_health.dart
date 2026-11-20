/// What the sync indicator and the sync-health screen show for a device that syncs
/// through a folder: the folder's alarms and refusals, read from the same tables
/// the op-log client uses, keyed by the folder id.
library;

import 'package:drift/drift.dart';

import '../sync_condition_class.dart';
import '../sync_database.dart';
import '../sync_health.dart';

class FolderSyncRows {
  const FolderSyncRows({
    required this.alarms,
    required this.refusals,
    required this.pendingRecordCount,
  });

  final List<IntegrityAlarmRow> alarms;
  final List<QuarantineRow> refusals;
  final int pendingRecordCount;
}

Future<FolderSyncRows> readFolderSyncRows(SyncDatabase database, String folderId) async {
  final alarms = await (database.select(database.integrityAlarms)
        ..where((row) => row.workspaceId.equals(folderId))
        ..orderBy([(row) => OrderingTerm(expression: row.id)]))
      .get();
  final refusals = await (database.select(database.quarantinedOps)
        ..where((row) => row.workspaceId.equals(folderId))
        ..orderBy([(row) => OrderingTerm(expression: row.id)]))
      .get();
  final pendingCount = database.folderPendingAppends.id.count();
  final pending = await (database.selectOnly(database.folderPendingAppends)
        ..addColumns([pendingCount])
        ..where(database.folderPendingAppends.folderId.equals(folderId)))
      .map((row) => row.read(pendingCount) ?? 0)
      .getSingle();
  return FolderSyncRows(alarms: alarms, refusals: refusals, pendingRecordCount: pending);
}

/// The same fold the op-log client's health query does, over a folder's rows.
SyncHealth folderHealthOf(FolderSyncRows rows) {
  final standing = [for (final alarm in rows.alarms) if (alarm.resolvedAt == null) alarm];
  final refused = [for (final row in rows.refusals) if (row.releasedAt == null) row];
  return SyncHealth(
    pendingOpCount: rows.pendingRecordCount,
    unresolvedAlarmCount: standing.length,
    actionableAlarmCount: standing
        .where((alarm) => classOfAlarmCode(alarm.kind) == SyncConditionClass.actionable)
        .length,
    quarantineCount: refused.length,
    reportableQuarantineCount: refused
        .where((row) => classOfRefusalCode(row.reason) != SyncConditionClass.transient)
        .length,
    alarmKinds: {for (final alarm in standing) alarm.kind},
  );
}

/// Live rows for a folder; emits once on subscription and again on any change.
Stream<FolderSyncRows> watchFolderSyncRows(SyncDatabase database, String folderId) =>
    database
        .customSelect(
          'SELECT 1',
          readsFrom: {
            database.integrityAlarms,
            database.quarantinedOps,
            database.folderPendingAppends,
          },
        )
        .watch()
        .asyncMap((_) => readFolderSyncRows(database, folderId));
