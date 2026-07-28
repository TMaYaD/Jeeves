/// What the sync surface reports — the replacement for the PowerSync
/// `SyncStatus` indicator.
///
/// **One class, one file.** [unresolvedAlarmCount] and [alarmKinds] come from the
/// `integrity_alarms` rows with `resolved_at IS NULL`; [pendingOpCount],
/// [quarantineCount] and [lastSyncedAt] from the outbox, the still-unreleased
/// quarantine rows and the pull cursor. #553 swaps the provider behind it.
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

  /// Accusations that still stand: `integrity_alarms` with `resolved_at IS NULL`.
  final int unresolvedAlarmCount;

  /// Ops still refused by a fail-closed rule: never applied, always surfaced.
  /// A refusal that was later re-admitted (a reorder that healed) stops counting
  /// here and stays inspectable.
  final int quarantineCount;

  /// The distinct kinds of the unresolved alarms.
  final Set<String> alarmKinds;

  /// When the last pull completed. Null before the first successful pull.
  final DateTime? lastSyncedAt;

  bool get clean => pendingOpCount == 0 && unresolvedAlarmCount == 0;

  /// Something the user is owed an explanation for: an accusation that still
  /// stands, or an op the device refused to apply. Derived for the same reason
  /// [clean] is — the indicator renders this state from two counts, and a
  /// stored flag would be free to disagree with them.
  bool get degraded => unresolvedAlarmCount > 0 || quarantineCount > 0;

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
