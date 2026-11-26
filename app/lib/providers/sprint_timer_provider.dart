/// Sprint timer state and notifier (Issues #47, #910, #911).
///
/// Binds a focus Sprint + Break cycle to the open TimeLog. **The recorded Sprint
/// is the only source of truth**: the notifier derives its whole state from the
/// `sprints` table, the open TimeLog and the synced break length through
/// [deriveSprintTimerState], a pure function of (record, `now`), and the
/// one-second ticker only re-evaluates it. Nothing is read from device-only
/// storage, so a Sprint started on one device shows on every other, and a
/// restart resumes from the record.
///
/// Which Break is the long one is derived the same way — from the recorded
/// Sprints and the synced settings, never stored ([longBreakDecision]) —
/// so every device reaches the same answer without anything new to sync.
///
/// Restoring never writes: past its set length a Sprint reads as overtime — the
/// same as in the foreground — instead of being turned into a Break, because on a
/// shared record that would let one device end a Sprint another is still running.
library;

import 'dart:async';

import 'package:drift/drift.dart' show OrderingTerm, TableUpdateQuery;
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/sprint_dao.dart';
import '../database/gtd_database.dart';
import '../models/focus_settings.dart';
import '../models/long_break.dart';
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

  /// The length of the Break in progress: the short Break's, or the long
  /// Break's when [isLongBreak] holds.
  final int currentBreakDurationMinutes;

  /// True while the Break in progress is the long one (issue #911).
  final bool isLongBreak;

  /// The Sprints in the run the long Break came from.
  ///
  /// The run holds the Sprints since the count last restarted, so it is not
  /// the setting the user chose: a Sprint that ran over brings the long
  /// Break after fewer Sprints than the setting names. Carried with the
  /// state so the copy that names a count — "four sprints" — names the count
  /// the user actually reached. Zero when no long Break is in progress.
  final int longBreakSprintCount;
  // Timestamp of the most recent break completion (null if none this session).
  final DateTime? lastBreakEndedAt;

  /// Length of the Break that `lastBreakEndedAt` closed. The cooldown lasts
  /// that long: a long Break is not forgotten after a short Break's worth.
  final int lastBreakDurationMinutes;

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
    this.currentBreakDurationMinutes = 3,
    this.isLongBreak = false,
    this.longBreakSprintCount = 0,
    this.lastBreakEndedAt,
    this.lastBreakDurationMinutes = 3,
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
        Duration(minutes: lastBreakDurationMinutes);
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
    int? currentBreakDurationMinutes,
    bool? isLongBreak,
    int? longBreakSprintCount,
    DateTime? lastBreakEndedAt,
    int? lastBreakDurationMinutes,
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
        currentBreakDurationMinutes:
            currentBreakDurationMinutes ?? this.currentBreakDurationMinutes,
        isLongBreak: isLongBreak ?? this.isLongBreak,
        longBreakSprintCount:
            longBreakSprintCount ?? this.longBreakSprintCount,
        lastBreakEndedAt: lastBreakEndedAt ?? this.lastBreakEndedAt,
        lastBreakDurationMinutes:
            lastBreakDurationMinutes ?? this.lastBreakDurationMinutes,
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
///   overtime once `ended_at + break length` has passed. The Break is the long
///   one when the run of Sprints has spent its budget (issue #911).
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
  required int longBreakMinutesSetting,
  required int sprintsBeforeLongBreakSetting,
  required DateTime now,
  String? suppressedSprintId,
}) {
  final latest = sprints.isEmpty ? null : sprints.last;
  final lastBreakEndedAt =
      sprints.length >= 2 ? latest!.startedAtUtc.toLocal() : null;
  // The Break that ended when the latest Sprint began was the one after the
  // Sprint before it; the cooldown lasts as long as that Break did.
  final lastBreakDurationMinutes = sprints.length >= 2 &&
          longBreakDecision(
            sprints: sprints,
            sprintId: sprints[sprints.length - 2].id,
            sprintDurationMinutes: sprintMinutesSetting,
            shortBreakDurationMinutes: breakMinutesSetting,
            longBreakDurationMinutes: longBreakMinutesSetting,
            sprintsBeforeLongBreak: sprintsBeforeLongBreakSetting,
          ).isLong
      ? longBreakMinutesSetting
      : breakMinutesSetting;
  if (activeLog == null) {
    return SprintTimerState(
      sprintDurationMinutes: sprintMinutesSetting,
      currentBreakDurationMinutes: breakMinutesSetting,
      lastBreakEndedAt: lastBreakEndedAt,
      lastBreakDurationMinutes: lastBreakDurationMinutes,
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
  final sprintMinutes =
      latestOnAction?.plannedDurationMinutes ?? sprintMinutesSetting;
  final recorded = sprintsOnAction.length;

  // Which Break comes after the latest Sprint: the long one when the run of
  // Sprints has spent its budget, the short one otherwise (issue #911). A
  // running or suppressed Sprint has no Break after it yet, and reads short.
  // The run it came from says how many Sprints the user actually did, which
  // is not the setting: a Sprint that ran over brings the long Break after
  // fewer Sprints than the setting names.
  final longBreak = latestOnAction == null
      ? null
      : longBreakDecision(
          sprints: sprints,
          sprintId: latestOnAction.id,
          sprintDurationMinutes: sprintMinutesSetting,
          shortBreakDurationMinutes: breakMinutesSetting,
          longBreakDurationMinutes: longBreakMinutesSetting,
          sprintsBeforeLongBreak: sprintsBeforeLongBreakSetting,
        );
  final isLongBreak = longBreak?.isLong ?? false;
  final longBreakSprintCount =
      longBreak != null && longBreak.isLong ? longBreak.sprintCount : 0;
  final breakMinutes =
      isLongBreak ? longBreakMinutesSetting : breakMinutesSetting;

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
        currentBreakDurationMinutes: breakMinutes,
        isLongBreak: isLongBreak,
        longBreakSprintCount: longBreakSprintCount,
        lastBreakEndedAt: lastBreakEndedAt,
        lastBreakDurationMinutes: lastBreakDurationMinutes,
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
  int get _shortBreakMinutes =>
      ref.read(focusSettingsProvider).shortBreakDurationMinutes;
  int get _longBreakMinutes =>
      ref.read(focusSettingsProvider).longBreakDurationMinutes;
  int get _sprintsBeforeLongBreak =>
      ref.read(focusSettingsProvider).sprintsBeforeLongBreak;

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
      // The Break that follows may be the long one, and its length is the
      // one the countdown runs on — the reload has already derived it.
      await _scheduleBreakEnd(
        endedAt.add(Duration(minutes: state.currentBreakDurationMinutes)),
        state.currentBreakDurationMinutes,
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
      sprintMinutesSetting:
          _activeLog == null ? kDefaultSprintDurationMinutes : _sprintMinutes,
      breakMinutesSetting: _activeLog == null
          ? kDefaultShortBreakDurationMinutes
          : _shortBreakMinutes,
      longBreakMinutesSetting: _activeLog == null
          ? kDefaultLongBreakDurationMinutes
          : _longBreakMinutes,
      sprintsBeforeLongBreakSetting: _activeLog == null
          ? kDefaultSprintsBeforeLongBreak
          : _sprintsBeforeLongBreak,
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
    _reconcileBreakNotification(next);
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

  /// Returns whether the reminder was scheduled.
  Future<bool> _scheduleEndNotification(
    DateTime endTime, {
    required bool isFocus,
    String? taskTitle,
    int breakDurationMinutes = kDefaultShortBreakDurationMinutes,
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
        await svc.scheduleBreakEndNotification(
          endTime: endTime,
          durationMinutes: breakDurationMinutes,
        );
      }
      return true;
    } catch (error) {
      debugPrint('Sprint end notification not scheduled: $error');
      return false;
    }
  }

  /// The Break-end reminder as last scheduled, so a change to the Break's
  /// length (a setting edited mid-Break) can replace it and a plain
  /// one-second tick cannot.
  DateTime? _scheduledBreakEndAt;
  int? _scheduledBreakMinutes;

  /// True from the first attempt to schedule this Break's reminder until the
  /// Break is cancelled, so an attempt that failed is retried rather than
  /// mistaken for a Break that never wanted one.
  bool _breakReminderWanted = false;
  DateTime? _breakReminderRetryNotBefore;
  @visibleForTesting
  static Duration breakReminderRetryDelay = const Duration(seconds: 15);

  void _reconcileBreakNotification(SprintTimerState next) {
    if (!_breakReminderWanted || _breakScheduleInFlight) return;
    if (next.phase != SprintPhase.break_) return;
    final endAt = DateTime.now().add(next.remaining);
    final plannedEndAt = _scheduledBreakEndAt;
    if (plannedEndAt == null) {
      // The last attempt failed, so nothing is known to be in place.
      final retryNotBefore = _breakReminderRetryNotBefore;
      if (retryNotBefore != null && DateTime.now().isBefore(retryNotBefore)) {
        return;
      }
    } else {
      final moved =
          endAt.difference(plannedEndAt).abs() > const Duration(seconds: 2);
      if (!moved &&
          next.currentBreakDurationMinutes == _scheduledBreakMinutes) {
        return;
      }
    }
    unawaited(_scheduleBreakEnd(endAt, next.currentBreakDurationMinutes));
  }

  /// Bumped by every cancel, so a schedule that was already in flight when
  /// the Break was cancelled can tell it is stale.
  int _breakNotificationGeneration = 0;
  bool _breakScheduleInFlight = false;

  Future<void> _scheduleBreakEnd(DateTime endAt, int minutes) async {
    final generation = _breakNotificationGeneration;
    _breakReminderWanted = true;
    _breakScheduleInFlight = true;
    final bool scheduled;
    try {
      scheduled = await _scheduleEndNotification(
        endAt,
        isFocus: false,
        breakDurationMinutes: minutes,
      );
    } finally {
      _breakScheduleInFlight = false;
    }
    if (generation != _breakNotificationGeneration) {
      // The Break was skipped or ended while this reminder was being
      // scheduled: take it back rather than let it fire for a Break that is
      // over, and do not record it.
      if (scheduled) {
        try {
          await ref
              .read(notificationServiceProvider)
              .cancelBreakEndNotification();
        } catch (error) {
          debugPrint('Stale Break reminder not cancelled: $error');
        }
      }
      return;
    }
    // Recorded only once it exists, so a failed schedule is not mistaken for
    // a reminder that is already in place.
    if (scheduled) {
      _scheduledBreakEndAt = endAt;
      _scheduledBreakMinutes = minutes;
      _breakReminderRetryNotBefore = null;
    } else {
      // A failed replacement may already have cancelled the reminder it was
      // replacing, so the old record cannot be trusted either: forget it and
      // let the next tick try again once the retry delay has passed.
      _scheduledBreakEndAt = null;
      _scheduledBreakMinutes = null;
      _breakReminderRetryNotBefore =
          DateTime.now().add(breakReminderRetryDelay);
    }
  }

  Future<void> _cancelSprintNotifications() async {
    _breakNotificationGeneration++;
    _breakReminderWanted = false;
    _breakReminderRetryNotBefore = null;
    _scheduledBreakEndAt = null;
    _scheduledBreakMinutes = null;
    final svc = ref.read(notificationServiceProvider);
    await svc.cancelSprintNotifications();
  }
}
