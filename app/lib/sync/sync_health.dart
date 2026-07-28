/// What the sync surface reports — the replacement for the PowerSync
/// `SyncStatus` indicator.
///
/// **One class, one file**, shared verbatim with #551's integrity work: that
/// slice fills [unresolvedAlarmCount] and [alarmKinds] from its IntegrityAlarms
/// rows (`resolved_at IS NULL`), this one fills [pendingOpCount],
/// [quarantineCount] and [lastSyncedAt], and #553 swaps the provider. Whichever
/// merges second reconciles to this shape.
///
/// Two rules the shape encodes deliberately:
///
/// * [clean] is a **derived getter**, never a stored status field or a degraded
///   enum. A status column would be a cache of the counts, free to disagree
///   with them.
/// * [lastSyncedAt] stamps on **pull completion, independent of flush state**.
///   The timestamp never claims healthy; a wedged outbox shows through
///   [pendingOpCount], and withholding the timestamp would only make a device
///   that is receiving fine look like one that is not.
///
/// The PowerSync dead-letter machinery does not carry over — quarantine plus
/// this surface is its successor. Its removal ships with #556.
library;

class SyncHealth {
  const SyncHealth({
    this.pendingOpCount = 0,
    this.unresolvedAlarmCount = 0,
    this.quarantineCount = 0,
    this.alarmKinds = const <String>{},
    this.lastSyncedAt,
  });

  /// Outbox rows this device authored that the server has not acknowledged.
  final int pendingOpCount;

  /// #551's IntegrityAlarms rows with `resolved_at IS NULL`. Reads 0 until that
  /// slice lands; [quarantineCount] carries the signal meanwhile.
  final int unresolvedAlarmCount;

  /// Ops refused by a fail-closed rule: never applied, always surfaced.
  final int quarantineCount;

  /// The distinct kinds of the unresolved alarms.
  final Set<String> alarmKinds;

  /// When the last pull completed. Null before the first successful pull.
  final DateTime? lastSyncedAt;

  bool get clean => pendingOpCount == 0 && unresolvedAlarmCount == 0;

  SyncHealth copyWith({
    int? pendingOpCount,
    int? unresolvedAlarmCount,
    int? quarantineCount,
    Set<String>? alarmKinds,
    DateTime? lastSyncedAt,
  }) =>
      SyncHealth(
        pendingOpCount: pendingOpCount ?? this.pendingOpCount,
        unresolvedAlarmCount: unresolvedAlarmCount ?? this.unresolvedAlarmCount,
        quarantineCount: quarantineCount ?? this.quarantineCount,
        alarmKinds: alarmKinds ?? this.alarmKinds,
        lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      );

  @override
  bool operator ==(Object other) =>
      other is SyncHealth &&
      other.pendingOpCount == pendingOpCount &&
      other.unresolvedAlarmCount == unresolvedAlarmCount &&
      other.quarantineCount == quarantineCount &&
      other.lastSyncedAt == lastSyncedAt &&
      other.alarmKinds.length == alarmKinds.length &&
      other.alarmKinds.containsAll(alarmKinds);

  @override
  int get hashCode => Object.hash(
        pendingOpCount,
        unresolvedAlarmCount,
        quarantineCount,
        lastSyncedAt,
        Object.hashAllUnordered(alarmKinds),
      );

  @override
  String toString() => 'SyncHealth(pending: $pendingOpCount, '
      'alarms: $unresolvedAlarmCount $alarmKinds, '
      'quarantined: $quarantineCount, lastSynced: $lastSyncedAt)';
}
