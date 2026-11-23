/// Sprint timer state and notifier (Issues #47, #910).
///
/// Binds a focus Sprint + Break cycle to the open TimeLog. **The recorded Sprint
/// is the only source of truth**: the notifier derives its whole state from the
/// `sprints` table, the open TimeLog and the synced break length through
/// [deriveSprintTimerState], a pure function of (record, `now`), and the
/// one-second ticker only re-evaluates it. Nothing is read from device-only
/// storage, so a Sprint started on one device shows on every other, and a
/// restart resumes from the record.
///
/// Restoring never writes: past its set length a Sprint reads as overtime — the
/// same as in the foreground — instead of being turned into a Break, because on a
/// shared record that would let one device end a Sprint another is still running.
library;

import 'dart:async';

import 'package:drift/drift.dart' show OrderingTerm, TableUpdateQuery;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/sprint_dao.dart';
import '../database/gtd_database.dart';
import '../services/notification_service.dart';
import 'auth_provider.dart';
import 'database_provider.dart';
import 'focus_settings_provider.dart';
import 'synced_preferences_provider.dart';

// ---------------------------------------------------------------------------
// Phase enum
// ---------------------------------------------------------------------------

enum SprintPhase {
  idle,
  focus,
  focusOvertime,
  break_,
  breakOvertime,
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class SprintTimerState {
  final SprintPhase phase;
  final String? activeTaskId;
  final String? activeTaskTitle;
  final int sprintNumber;
  final int totalSprints;
  final Duration remaining;
  final Duration total;
  final Duration overtime;
  final bool isProcessing;
  // Minutes used for the current (or last) sprint/break — set at startSprint.
  final int sprintDurationMinutes;
  final int breakDurationMinutes;
  // Timestamp of the most recent break completion (null if none this session).
  final DateTime? lastBreakEndedAt;

  const SprintTimerState({
    this.phase = SprintPhase.idle,
    this.activeTaskId,
    this.activeTaskTitle,
    this.sprintNumber = 1,
    this.totalSprints = 1,
    this.remaining = const Duration(minutes: 20),
    this.total = const Duration(minutes: 20),
    this.overtime = Duration.zero,
    this.isProcessing = false,
    this.sprintDurationMinutes = 20,
    this.breakDurationMinutes = 3,
    this.lastBreakEndedAt,
  });

  bool get isActive => phase != SprintPhase.idle;
  bool get isFocus =>
      phase == SprintPhase.focus || phase == SprintPhase.focusOvertime;
  bool get isBreak =>
      phase == SprintPhase.break_ || phase == SprintPhase.breakOvertime;
  bool get isOvertime =>
      phase == SprintPhase.focusOvertime || phase == SprintPhase.breakOvertime;

  /// Countdown progress: 1.0 = full (start), 0.0 = empty (end).
  double get progress {
    if (total.inSeconds == 0) return 0;
    return (remaining.inSeconds / total.inSeconds).clamp(0.0, 1.0);
  }

  /// Overtime progress: 0.0 = empty (start), 1.0 = full (end, 2× phase duration).
  double get overtimeProgress {
    if (total.inSeconds == 0) return 0;
    return (overtime.inSeconds / total.inSeconds).clamp(0.0, 1.0);
  }

  /// True in the last 15% of a normal phase — Jeeves copy and UI affordances
  /// use this to nudge the user toward the phase transition.
  bool get isNearPhaseEnd => !isOvertime && progress <= 0.15;

  /// True when a break ended recently enough that rest shouldn't be suggested.
  /// The cooldown window equals the break duration itself.
  bool get isPostBreakCooldown {
    if (lastBreakEndedAt == null) return false;
    return DateTime.now().difference(lastBreakEndedAt!) <
        Duration(minutes: breakDurationMinutes);
  }

  SprintTimerState copyWith({
    SprintPhase? phase,
    String? activeTaskId,
    String? activeTaskTitle,
    int? sprintNumber,
    int? totalSprints,
    Duration? remaining,
    Duration? total,
    Duration? overtime,
    bool? isProcessing,
    int? sprintDurationMinutes,
    int? breakDurationMinutes,
    DateTime? lastBreakEndedAt,
  }) =>
      SprintTimerState(
        phase: phase ?? this.phase,
        activeTaskId: activeTaskId ?? this.activeTaskId,
        activeTaskTitle: activeTaskTitle ?? this.activeTaskTitle,
        sprintNumber: sprintNumber ?? this.sprintNumber,
        totalSprints: totalSprints ?? this.totalSprints,
        remaining: remaining ?? this.remaining,
        total: total ?? this.total,
        overtime: overtime ?? this.overtime,
        isProcessing: isProcessing ?? this.isProcessing,
        sprintDurationMinutes:
            sprintDurationMinutes ?? this.sprintDurationMinutes,
        breakDurationMinutes: breakDurationMinutes ?? this.breakDurationMinutes,
        lastBreakEndedAt: lastBreakEndedAt ?? this.lastBreakEndedAt,
      );
}

// ---------------------------------------------------------------------------
// Derivation
// ---------------------------------------------------------------------------

/// The ms-truncated UTC instant of [value] — the grain a recorded Sprint's
/// instants have, so a Sprint started in the same instant a TimeLog opened is
/// never read as having started before it.
DateTime _floorToMillisecond(DateTime value) =>
    DateTime.fromMillisecondsSinceEpoch(value.millisecondsSinceEpoch,
        isUtc: true);

int _calcTotalSprints(int? estimateMinutes, int sprintMinutes) {
  if (estimateMinutes == null || estimateMinutes <= sprintMinutes) return 1;
  return (estimateMinutes / sprintMinutes).ceil();
}

/// The timer state as a pure function of the recorded Sprints, the open
/// TimeLog, the synced settings and [now].
///
/// * No open TimeLog: idle.
/// * The latest Sprint is running on the TimeLog's Action: focus, or focus
///   overtime once `started_at + planned length` has passed.
/// * The latest Sprint ended at or after the TimeLog opened: break, or break
///   overtime once `ended_at + break length` has passed.
/// * Otherwise idle.
///
/// `sprintNumber` counts the recorded Sprints on the TimeLog's Action, the
/// running one included (an idle timer reports the number the next one would
/// have). [suppressedSprintId] names a Sprint the user stopped on this device;
/// it never reads as a break.
SprintTimerState deriveSprintTimerState({
  required List<SprintRecord> sprints,
  required TimeLog? activeLog,
  required Todo? activeTask,
  required int sprintMinutesSetting,
  required int breakMinutesSetting,
  required DateTime now,
  String? suppressedSprintId,
}) {
  final latest = sprints.isEmpty ? null : sprints.last;
  final lastBreakEndedAt =
      sprints.length >= 2 ? latest!.startedAtUtc.toLocal() : null;
  if (activeLog == null) {
    return SprintTimerState(
      sprintDurationMinutes: sprintMinutesSetting,
      breakDurationMinutes: breakMinutesSetting,
      lastBreakEndedAt: lastBreakEndedAt,
    );
  }

  final actionId = activeLog.actionId;
  final logStartedAtUtc =
      _floorToMillisecond(DateTime.parse(activeLog.startedAt).toUtc());
  final sprintsOnAction = actionId == null
      ? const <SprintRecord>[]
      : [for (final s in sprints) if (s.actionId == actionId) s];
  final latestOnAction = latest != null &&
          actionId != null &&
          latest.actionId == actionId &&
          latest.id != suppressedSprintId &&
          !latest.startedAtUtc.isBefore(logStartedAtUtc)
      ? latest
      : null;

  final nowUtc = now.toUtc();
  final breakMinutes = breakMinutesSetting;
  final sprintMinutes =
      latestOnAction?.plannedDurationMinutes ?? sprintMinutesSetting;
  final recorded = sprintsOnAction.length;

  SprintTimerState build({
    required SprintPhase phase,
    required int sprintNumber,
    Duration remaining = Duration.zero,
    Duration total = Duration.zero,
    Duration overtime = Duration.zero,
  }) =>
      SprintTimerState(
        phase: phase,
        activeTaskId: activeLog.taskId,
        activeTaskTitle: activeTask?.title,
        sprintNumber: sprintNumber,
        totalSprints: _calcTotalSprints(activeTask?.timeEstimate, sprintMinutes) >
                sprintNumber
            ? _calcTotalSprints(activeTask?.timeEstimate, sprintMinutes)
            : sprintNumber,
        remaining: remaining,
        total: total,
        overtime: overtime,
        sprintDurationMinutes: sprintMinutes,
        breakDurationMinutes: breakMinutes,
        lastBreakEndedAt: lastBreakEndedAt,
      );

  if (latestOnAction != null && latestOnAction.isRunning) {
    final total = Duration(minutes: latestOnAction.plannedDurationMinutes);
    var elapsed = nowUtc.difference(latestOnAction.startedAtUtc);
    if (elapsed.isNegative) elapsed = Duration.zero;
    if (elapsed < total) {
      return build(
        phase: SprintPhase.focus,
        sprintNumber: recorded,
        remaining: total - elapsed,
        total: total,
      );
    }
    final overtime = elapsed - total;
    return build(
      phase: SprintPhase.focusOvertime,
      sprintNumber: recorded,
      total: total,
      overtime: overtime > total ? total : overtime,
    );
  }

  final endedAtUtc = latestOnAction?.endedAtUtc;
  if (latestOnAction != null &&
      endedAtUtc != null &&
      !endedAtUtc.isBefore(logStartedAtUtc)) {
    final total = Duration(minutes: breakMinutes);
    final breakEndsAtUtc = endedAtUtc.add(total);
    if (nowUtc.isBefore(breakEndsAtUtc)) {
      return build(
        phase: SprintPhase.break_,
        sprintNumber: recorded,
        remaining: breakEndsAtUtc.difference(nowUtc),
        total: total,
      );
    }
    final overtime = nowUtc.difference(breakEndsAtUtc);
    return build(
      phase: SprintPhase.breakOvertime,
      sprintNumber: recorded,
      total: total,
      overtime: overtime > total ? total : overtime,
    );
  }

  return build(phase: SprintPhase.idle, sprintNumber: recorded + 1);
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

final sprintTimerProvider =
    NotifierProvider<SprintTimerNotifier, SprintTimerState>(
  SprintTimerNotifier.new,
);

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

class SprintTimerNotifier extends Notifier<SprintTimerState> {
  Timer? _ticker;
  StreamSubscription<Object?>? _tableUpdates;

  List<SprintRecord> _sprints = const [];
  TimeLog? _activeLog;
  Todo? _activeTask;
  String? _suppressedSprintId;
  bool _disposed = false;

  @override
  SprintTimerState build() {
    ref.onDispose(() {
      _disposed = true;
      _ticker?.cancel();
      _tableUpdates?.cancel();
    });
    final db = _databaseOrNull();
    if (db != null) {
      // `tableUpdates` is a plain broadcast stream (no query, no close timer);
      // each event re-reads the record, so a Sprint a peer started — projected
      // in by the sync host — shows up here.
      _tableUpdates = db
          .tableUpdates(TableUpdateQuery.onAllTables([db.sprints, db.timeLogs]))
          .listen((_) => unawaited(_reload()));
      // Fire-and-forget: state emitted by [_reload] rebuilds listeners.
      unawaited(_reload());
    }
    return const SprintTimerState();
  }

  /// The domain store, or null while it is not available (the store is still
  /// opening, or a test has not provided one): the timer then stays idle.
  GtdDatabase? _databaseOrNull() {
    try {
      return ref.read(databaseProvider);
    } catch (_) {
      return null;
    }
  }

  int get _sprintMinutes =>
      ref.read(focusSettingsProvider).sprintDurationMinutes;
  int get _breakMinutes => ref.read(focusSettingsProvider).breakDurationMinutes;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Starts a recorded Sprint on [task] using the synced Sprint length.
  ///
  /// Reads the record first: when this Outcome already has a running Sprint —
  /// started on another device, or before a restart — it is adopted, not
  /// duplicated.
  Future<void> startSprint(Todo task) async {
    if (state.isProcessing) return;
    final db = _databaseOrNull();
    if (db == null) return;
    state = state.copyWith(isProcessing: true);
    try {
      HapticFeedback.mediumImpact();
      await _reload();
      // Adopt any live phase for this Outcome (Sprint, Break or either
      // overtime): a restart or a second device opening Focus mid-Break must
      // not end the Break and record a new Sprint.
      if (state.isActive && state.activeTaskId == task.id) return;
      await _startRecordedSprint(db, task);
    } finally {
      if (state.isProcessing) state = state.copyWith(isProcessing: false);
    }
  }

  /// Ends the current Sprint early and starts a Break.
  Future<void> startBreak() async {
    if (!state.isFocus || state.isProcessing) return;
    await _endSprint(HapticFeedback.lightImpact);
  }

  /// Stops the Sprint and returns to idle. The open TimeLog is closed by
  /// [FocusSessionDao.setCurrentTask] when [FocusModeNotifier.endFocus] is called.
  Future<void> stopSprint() async {
    if (state.isProcessing) return;
    final db = _databaseOrNull();
    if (db == null) {
      state = const SprintTimerState();
      return;
    }
    state = state.copyWith(isProcessing: true);
    try {
      _stopTicker();
      HapticFeedback.mediumImpact();
      await _cancelSprintNotifications();
      // Remember which Sprint we stop before reloading: a peer's Sprint may be
      // projected in between and must not be the one suppressed.
      final stoppedSprintId = _runningSprintId();
      await db.sprintDao
          .endRunningSprint(userId: ref.read(currentUserIdProvider));
      await _reload();
      // The TimeLog stays open until the caller closes it; until then the
      // Sprint just stopped must not read as a Break.
      _suppressedSprintId = stoppedSprintId;
      _recompute();
    } finally {
      if (state.isProcessing) state = state.copyWith(isProcessing: false);
    }
  }

  /// Ends the Sprint (recording its end) and transitions the timer to the Break.
  Future<void> completeSprint() async {
    if (state.isProcessing) return;
    await _endSprint(HapticFeedback.heavyImpact);
  }

  /// Skips the Break and starts the next Sprint immediately (from break_ or
  /// breakOvertime).
  Future<void> skipBreak() async {
    if (!state.isBreak || state.isProcessing) return;
    final db = _databaseOrNull();
    final taskId = state.activeTaskId;
    if (db == null || taskId == null) return;
    state = state.copyWith(isProcessing: true);
    try {
      HapticFeedback.lightImpact();
      await _cancelSprintNotifications();
      final task = await db.todoDao.getTodo(taskId);
      if (task == null) return;
      await _startRecordedSprint(db, task);
    } finally {
      if (state.isProcessing) state = state.copyWith(isProcessing: false);
    }
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Id of the user's running Sprint (latest, no stored end), or null.
  String? _runningSprintId() {
    if (_sprints.isEmpty) return null;
    final latest = _sprints.last;
    return latest.storedEndedAtUtc == null ? latest.id : null;
  }

  Future<void> _startRecordedSprint(GtdDatabase db, Todo task) async {
    // The synced setting loads asynchronously; right after launch the notifier
    // still holds defaults, and the wrong length would be recorded and synced.
    ref.read(focusSettingsProvider); // starts the settings watch if not yet
    try {
      // `exists`: a container that replaced the settings (as tests do) never
      // starts the synced-preferences load, and there is nothing to wait for.
      // ignore: deprecated_member_use
      if (ref.exists(syncedPreferencesProvider)) {
        await ref.read(syncedPreferencesProvider.future);
      }
    } catch (error) {
      debugPrint('Sprint length: synced preferences unavailable: $error');
    }
    final sprintMinutes = _sprintMinutes;
    final startedAt = DateTime.now();
    await db.sprintDao.startSprint(
      taskId: task.id,
      userId: ref.read(currentUserIdProvider),
      plannedDurationMinutes: sprintMinutes,
      now: startedAt,
    );
    _suppressedSprintId = null;
    await _reload();
    await _scheduleEndNotification(
      startedAt.add(Duration(minutes: sprintMinutes)),
      isFocus: true,
      taskTitle: task.title,
    );
  }

  Future<void> _endSprint(void Function() haptic) async {
    final db = _databaseOrNull();
    if (db == null) return;
    state = state.copyWith(isProcessing: true);
    try {
      _stopTicker();
      haptic();
      await _cancelSprintNotifications();
      final endedAt = DateTime.now();
      await db.sprintDao.endRunningSprint(
        userId: ref.read(currentUserIdProvider),
        now: endedAt,
      );
      await _reload();
      await _scheduleEndNotification(
        endedAt.add(Duration(minutes: _breakMinutes)),
        isFocus: false,
      );
    } finally {
      if (state.isProcessing) state = state.copyWith(isProcessing: false);
    }
  }

  /// Re-reads the record, the open TimeLog and its Outcome, then re-derives.
  Future<void> _reload() async {
    final db = _databaseOrNull();
    if (db == null || _disposed) return;
    final sprints = await db.sprintDao.getAllRecords();
    final openLogs = await (db.select(db.timeLogs)
          ..where((t) => t.endedAt.isNull())
          ..orderBy([(t) => OrderingTerm.desc(t.startedAt)]))
        .get();
    final log = openLogs.isEmpty ? null : openLogs.first;
    Todo? task = _activeTask;
    if (log == null) {
      task = null;
    } else if (task?.id != log.taskId) {
      task = await db.todoDao.getTodo(log.taskId);
    }
    if (_disposed) return;
    _sprints = sprints;
    _activeLog = log;
    _activeTask = task;
    _recompute();
  }

  /// Derives the state from the cached record at the current time, and keeps
  /// the ticker running exactly while there is something to count.
  void _recompute() {
    if (_disposed) return;
    final previous = state;
    var next = deriveSprintTimerState(
      sprints: _sprints,
      activeLog: _activeLog,
      activeTask: _activeTask,
      // The synced settings only matter once there is an engagement to time, so
      // an idle timer does not even instantiate them. A change to either is
      // picked up by the next one-second re-evaluation.
      sprintMinutesSetting: _activeLog == null ? 20 : _sprintMinutes,
      breakMinutesSetting: _activeLog == null ? 3 : _breakMinutes,
      now: DateTime.now(),
      suppressedSprintId: _suppressedSprintId,
    );
    next = next.copyWith(isProcessing: previous.isProcessing);
    if (previous.phase == SprintPhase.focus &&
            next.phase == SprintPhase.focusOvertime ||
        previous.phase == SprintPhase.break_ &&
            next.phase == SprintPhase.breakOvertime) {
      HapticFeedback.heavyImpact();
    }
    state = next;
    final counting = next.isActive && !(next.isOvertime && next.overtime >= next.total);
    if (counting) {
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _recompute());
    } else {
      _stopTicker();
    }
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  Future<void> _scheduleEndNotification(
    DateTime endTime, {
    required bool isFocus,
    String? taskTitle,
  }) async {
    // A reminder is a side effect: failing to schedule it must not undo the
    // Sprint that is already recorded.
    try {
      final svc = ref.read(notificationServiceProvider);
      if (isFocus) {
        await svc.scheduleSprintEndNotification(
          endTime: endTime,
          taskTitle: taskTitle ?? 'your task',
        );
      } else {
        await svc.scheduleBreakEndNotification(endTime: endTime);
      }
    } catch (error) {
      debugPrint('Sprint end notification not scheduled: $error');
    }
  }

  Future<void> _cancelSprintNotifications() async {
    final svc = ref.read(notificationServiceProvider);
    await svc.cancelSprintNotifications();
  }
}
