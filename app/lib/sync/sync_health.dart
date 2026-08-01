/// What the sync surface reports.
///
/// **One class, one file.** [unresolvedAlarmCount] and [alarmKinds] come from the
/// `integrity_alarms` rows with `resolved_at IS NULL`; [pendingOpCount],
/// [quarantineCount] and [lastSyncedAt] from the outbox, the still-unreleased
/// quarantine rows and the pull cursor. #553 swaps the provider behind it.
///
/// Three rules the shape encodes deliberately:
///
/// * [clean] is a **derived getter**, never a stored status field or a degraded
///   enum. A status column would be a cache of the counts, free to disagree
///   with them.
/// * **An accusation standing is not the same as the User being told something
///   is wrong.** [unresolvedAlarmCount] and [quarantineCount] say what stands;
///   [actionableAlarmCount] and [reportableQuarantineCount] say what that means
///   to the User, and only the first of those two turns the indicator red. The
///   classification lives in `sync_condition_class.dart` and is persisted
///   nowhere (ADR-0044).
/// * [lastSyncedAt] stamps on **pull completion, independent of flush state**.
///   The timestamp never claims healthy; a wedged outbox shows through
///   [pendingOpCount], and withholding the timestamp would only make a device
///   that is receiving fine look like one that is not.
///
/// There is no dead-letter table behind this: quarantine plus the alarm counts
/// above are the successor, and a refused op is evidence held in the log rather
/// than a row in a side table nothing drains.
library;

class SyncHealth {
  const SyncHealth({
    this.pendingOpCount = 0,
    this.unresolvedAlarmCount = 0,
    this.actionableAlarmCount = 0,
    this.quarantineCount = 0,
    this.reportableQuarantineCount = 0,
    this.alarmKinds = const <String>{},
    this.lastSyncedAt,
  });

  /// Outbox rows this device authored that the server has not acknowledged.
  final int pendingOpCount;

  /// Accusations that still stand: `integrity_alarms` with `resolved_at IS NULL`.
  ///
  /// **Unchanged in meaning**, and deliberately so: what stands is what stands,
  /// and the compaction gate still reads this. Only what is *called an error*
  /// moved, and it moved to [actionableAlarmCount].
  final int unresolvedAlarmCount;

  /// The subset of [unresolvedAlarmCount] whose kind is
  /// `SyncConditionClass.actionable` — the four kinds that mean something of the
  /// User's is stuck or lost.
  ///
  /// The only count that turns the indicator red. See ADR-0044 and
  /// `sync_condition_class.dart`.
  final int actionableAlarmCount;

  /// Ops still refused by a fail-closed rule: never applied, always surfaced.
  /// A refusal that was later re-admitted (a reorder that healed) stops counting
  /// here and stays inspectable.
  final int quarantineCount;

  /// The subset of [quarantineCount] that is not self-healing — every refusal
  /// reason except the five delivery gaps (a KeyWrap or an epoch that has not
  /// arrived yet).
  ///
  /// It makes the sync-health screen reachable; it never makes the indicator an
  /// error. A refusal is the app *working*: the bytes were refused, which is the
  /// outcome the fail-closed rule exists to produce.
  final int reportableQuarantineCount;

  /// The distinct kinds of the unresolved alarms.
  final Set<String> alarmKinds;

  /// When the last pull completed. Null before the first successful pull.
  final DateTime? lastSyncedAt;

  bool get clean => pendingOpCount == 0 && unresolvedAlarmCount == 0;

  /// **An error, and only an error.** True when an `actionable` alarm is
  /// standing: something of the User's is stuck or lost.
  ///
  /// It used to be `unresolvedAlarmCount > 0 || quarantineCount > 0`, which made
  /// a device red for conditions it had handled perfectly and — since almost
  /// nothing can clear an alarm — kept it red for ever. Fourteen of the eighteen
  /// alarm kinds and every refusal now report instead (ADR-0044).
  ///
  /// Derived for the same reason [clean] is: a stored flag would be free to
  /// disagree with the counts.
  bool get degraded => actionableAlarmCount > 0;

  /// **There is something to say.** True when the User has an account of events
  /// worth reading — whether or not any of it is an error.
  ///
  /// This is the whole condition for the sync-health screen being reachable. A
  /// device with nothing to report has no entry point at all, and neither does
  /// one whose only condition is self-healing: a KeyWrap that has not arrived is
  /// not an event, and offering a screen to read about it would reintroduce the
  /// interruption this classification exists to remove.
  bool get hasSomethingToReport =>
      unresolvedAlarmCount > 0 || reportableQuarantineCount > 0;

  SyncHealth copyWith({
    int? pendingOpCount,
    int? unresolvedAlarmCount,
    int? actionableAlarmCount,
    int? quarantineCount,
    int? reportableQuarantineCount,
    Set<String>? alarmKinds,
    DateTime? lastSyncedAt,
  }) =>
      SyncHealth(
        pendingOpCount: pendingOpCount ?? this.pendingOpCount,
        unresolvedAlarmCount: unresolvedAlarmCount ?? this.unresolvedAlarmCount,
        actionableAlarmCount: actionableAlarmCount ?? this.actionableAlarmCount,
        quarantineCount: quarantineCount ?? this.quarantineCount,
        reportableQuarantineCount:
            reportableQuarantineCount ?? this.reportableQuarantineCount,
        alarmKinds: alarmKinds ?? this.alarmKinds,
        lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      );

  @override
  bool operator ==(Object other) =>
      other is SyncHealth &&
      other.pendingOpCount == pendingOpCount &&
      other.unresolvedAlarmCount == unresolvedAlarmCount &&
      other.actionableAlarmCount == actionableAlarmCount &&
      other.quarantineCount == quarantineCount &&
      other.reportableQuarantineCount == reportableQuarantineCount &&
      other.lastSyncedAt == lastSyncedAt &&
      other.alarmKinds.length == alarmKinds.length &&
      other.alarmKinds.containsAll(alarmKinds);

  @override
  int get hashCode => Object.hash(
        pendingOpCount,
        unresolvedAlarmCount,
        actionableAlarmCount,
        quarantineCount,
        reportableQuarantineCount,
        lastSyncedAt,
        Object.hashAllUnordered(alarmKinds),
      );

  @override
  String toString() => 'SyncHealth(pending: $pendingOpCount, '
      'alarms: $unresolvedAlarmCount ($actionableAlarmCount actionable) '
      '$alarmKinds, quarantined: $quarantineCount '
      '($reportableQuarantineCount reportable), lastSynced: $lastSyncedAt)';
}
