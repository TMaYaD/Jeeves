/// Pomodoro sprint timer state and notifier (Issue #47).
///
/// Implements a 20-minute focus sprint + 3-minute break cycle bound to a
/// selected Focus Mode task. Timer state is persisted to SharedPreferences so
/// it survives app backgrounding; a local notification fires at expiry even
/// when the app is in the background.
library;

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/gtd_database.dart';
import '../services/notification_service.dart';
import 'auth_provider.dart';
import 'database_provider.dart';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const _kSprintDuration = Duration(minutes: 20);
const _kBreakDuration = Duration(minutes: 3);
const _kSprintMinutes = 20;

// SharedPreferences keys.
const _kPrefActiveTaskId = 'sprint_active_task_id';
const _kPrefActiveTaskTitle = 'sprint_active_task_title';
const _kPrefEndTime = 'sprint_end_time';
const _kPrefPhase = 'sprint_phase';
const _kPrefSprintNumber = 'sprint_sprint_number';
const _kPrefTotalSprints = 'sprint_total_sprints';
const _kPrefIsPaused = 'sprint_is_paused';
const _kPrefRemainingSeconds = 'sprint_remaining_seconds';

// Phase string values stored in SharedPreferences.
const _kPhaseFocus = 'focus';
const _kPhaseBreak = 'break';

// ---------------------------------------------------------------------------
// Phase enum
// ---------------------------------------------------------------------------

enum SprintPhase {
  idle,
  focus,
  break_,
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
  final bool isPaused;

  const SprintTimerState({
    this.phase = SprintPhase.idle,
    this.activeTaskId,
    this.activeTaskTitle,
    this.sprintNumber = 1,
    this.totalSprints = 1,
    this.remaining = _kSprintDuration,
    this.total = _kSprintDuration,
    this.isPaused = false,
  });

  bool get isActive => phase != SprintPhase.idle;
  bool get isFocus => phase == SprintPhase.focus;
  bool get isBreak => phase == SprintPhase.break_;

  /// 0.0 → 1.0, where 1.0 means the timer has fully elapsed.
  double get progress {
    if (total.inSeconds == 0) return 0;
    return 1 - (remaining.inSeconds / total.inSeconds);
  }

  SprintTimerState copyWith({
    SprintPhase? phase,
    String? activeTaskId,
    String? activeTaskTitle,
    int? sprintNumber,
    int? totalSprints,
    Duration? remaining,
    Duration? total,
    bool? isPaused,
  }) =>
      SprintTimerState(
        phase: phase ?? this.phase,
        activeTaskId: activeTaskId ?? this.activeTaskId,
        activeTaskTitle: activeTaskTitle ?? this.activeTaskTitle,
        sprintNumber: sprintNumber ?? this.sprintNumber,
        totalSprints: totalSprints ?? this.totalSprints,
        remaining: remaining ?? this.remaining,
        total: total ?? this.total,
        isPaused: isPaused ?? this.isPaused,
      );
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
  DateTime? _endTime;

  @override
  SprintTimerState build() {
    ref.onDispose(() => _ticker?.cancel());
    _restoreFromPrefs();
    return const SprintTimerState();
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Starts a 20-minute focus sprint for [task].
  Future<void> startSprint(Todo task) async {
    _ticker?.cancel();
    HapticFeedback.mediumImpact();

    final totalSprints = _calcTotalSprints(task.timeEstimate);
    final sprintNumber = _calcSprintNumber(task.timeSpentMinutes);
    _endTime = DateTime.now().add(_kSprintDuration);

    state = SprintTimerState(
      phase: SprintPhase.focus,
      activeTaskId: task.id,
      activeTaskTitle: task.title,
      sprintNumber: sprintNumber,
      totalSprints: totalSprints,
      remaining: _kSprintDuration,
      total: _kSprintDuration,
    );

    await _persist(isPaused: false);
    await _scheduleEndNotification(
        _endTime!, isFocus: true, taskTitle: task.title);
    _startTicker();
  }

  /// Pauses the running timer.
  Future<void> pauseSprint() async {
    if (!state.isActive || state.isPaused) return;
    _ticker?.cancel();
    HapticFeedback.lightImpact();

    state = state.copyWith(isPaused: true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPrefIsPaused, true);
    await prefs.setInt(_kPrefRemainingSeconds, state.remaining.inSeconds);
    await _cancelSprintNotifications();
  }

  /// Resumes a paused timer.
  Future<void> resumeSprint() async {
    if (!state.isActive || !state.isPaused) return;
    HapticFeedback.lightImpact();

    _endTime = DateTime.now().add(state.remaining);
    state = state.copyWith(isPaused: false);
    await _persist(isPaused: false);
    await _scheduleEndNotification(
      _endTime!,
      isFocus: state.isFocus,
      taskTitle: state.activeTaskTitle,
    );
    _startTicker();
  }

  /// Stops the sprint entirely, returning to idle.
  Future<void> stopSprint() async {
    _ticker?.cancel();
    HapticFeedback.mediumImpact();
    await _cancelSprintNotifications();
    await _clearPrefs();
    state = const SprintTimerState();
  }

  /// Records a completed sprint, logs time to the task, then starts the break.
  Future<void> completeSprint() async {
    _ticker?.cancel();
    HapticFeedback.heavyImpact();
    await _cancelSprintNotifications();
    await _logSprintTimeToTask();
    await _startBreak();
  }

  /// Skips the break timer and returns to idle.
  Future<void> skipBreak() async {
    _ticker?.cancel();
    HapticFeedback.lightImpact();
    await _cancelSprintNotifications();
    await _clearPrefs();
    state = const SprintTimerState();
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  Future<void> _restoreFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final activeTaskId = prefs.getString(_kPrefActiveTaskId);
    if (activeTaskId == null || activeTaskId.isEmpty) return;

    final endTimeStr = prefs.getString(_kPrefEndTime);
    final phaseStr = prefs.getString(_kPrefPhase);
    if (endTimeStr == null || phaseStr == null) return;

    final sprintNumber = prefs.getInt(_kPrefSprintNumber) ?? 1;
    final totalSprints = prefs.getInt(_kPrefTotalSprints) ?? 1;
    final isPaused = prefs.getBool(_kPrefIsPaused) ?? false;
    final remainingSeconds = prefs.getInt(_kPrefRemainingSeconds);
    final taskTitle = prefs.getString(_kPrefActiveTaskTitle) ?? '';

    final phase =
        phaseStr == _kPhaseBreak ? SprintPhase.break_ : SprintPhase.focus;
    final total = phase == SprintPhase.focus ? _kSprintDuration : _kBreakDuration;

    Duration remaining;
    if (isPaused && remainingSeconds != null) {
      remaining = Duration(seconds: remainingSeconds);
    } else {
      _endTime = DateTime.tryParse(endTimeStr);
      if (_endTime == null) return;
      remaining = _endTime!.difference(DateTime.now());
      if (remaining.isNegative) {
        // Timer expired while app was backgrounded.
        _onTimerExpiredBackground(phase);
        return;
      }
    }

    state = SprintTimerState(
      phase: phase,
      activeTaskId: activeTaskId,
      activeTaskTitle: taskTitle,
      sprintNumber: sprintNumber,
      totalSprints: totalSprints,
      remaining: remaining,
      total: total,
      isPaused: isPaused,
    );

    if (!isPaused) _startTicker();
  }

  void _onTimerExpiredBackground(SprintPhase expiredPhase) {
    if (expiredPhase == SprintPhase.focus) {
      _logSprintTimeToTask().then((_) => _startBreak());
    } else {
      _clearPrefs();
      state = const SprintTimerState();
    }
  }

  Future<void> _startBreak() async {
    _endTime = DateTime.now().add(_kBreakDuration);
    state = state.copyWith(
      phase: SprintPhase.break_,
      remaining: _kBreakDuration,
      total: _kBreakDuration,
      isPaused: false,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPrefEndTime, _endTime!.toIso8601String());
    await prefs.setString(_kPrefPhase, _kPhaseBreak);
    await prefs.setBool(_kPrefIsPaused, false);
    await _scheduleEndNotification(_endTime!, isFocus: false);
    _startTicker();
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    if (_endTime == null) return;
    final remaining = _endTime!.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      _ticker?.cancel();
      _onTimerExpired();
      return;
    }
    state = state.copyWith(remaining: remaining);
  }

  void _onTimerExpired() {
    HapticFeedback.heavyImpact();
    if (state.isFocus) {
      _logSprintTimeToTask().then((_) => _startBreak());
    } else {
      _clearPrefs();
      state = const SprintTimerState();
    }
  }

  Future<void> _logSprintTimeToTask() async {
    final taskId = state.activeTaskId;
    if (taskId == null) return;
    try {
      final db = ref.read(databaseProvider);
      final userId = ref.read(currentUserIdProvider);
      await (db.update(db.todos)
            ..where((t) => t.id.equals(taskId).and(t.userId.equals(userId))))
          .write(TodosCompanion(
        timeSpentMinutes: Value(
          // We do a raw increment; the DAO handles exact accounting on state
          // transitions. Here we just add the sprint duration.
          (await _currentTimeSpent(db, taskId, userId)) + _kSprintMinutes,
        ),
        updatedAt: Value(DateTime.now()),
      ));
    } catch (_) {
      // Non-fatal: time tracking is best-effort.
    }
  }

  Future<int> _currentTimeSpent(
      GtdDatabase db, String taskId, String userId) async {
    final row = await (db.select(db.todos)
          ..where((t) => t.id.equals(taskId).and(t.userId.equals(userId))))
        .getSingleOrNull();
    return row?.timeSpentMinutes ?? 0;
  }

  Future<void> _persist({required bool isPaused}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPrefActiveTaskId, state.activeTaskId ?? '');
    await prefs.setString(_kPrefActiveTaskTitle, state.activeTaskTitle ?? '');
    await prefs.setString(_kPrefEndTime, _endTime?.toIso8601String() ?? '');
    await prefs.setString(
        _kPrefPhase, state.isFocus ? _kPhaseFocus : _kPhaseBreak);
    await prefs.setInt(_kPrefSprintNumber, state.sprintNumber);
    await prefs.setInt(_kPrefTotalSprints, state.totalSprints);
    await prefs.setBool(_kPrefIsPaused, isPaused);
  }

  Future<void> _clearPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kPrefActiveTaskId);
    await prefs.remove(_kPrefActiveTaskTitle);
    await prefs.remove(_kPrefEndTime);
    await prefs.remove(_kPrefPhase);
    await prefs.remove(_kPrefSprintNumber);
    await prefs.remove(_kPrefTotalSprints);
    await prefs.remove(_kPrefIsPaused);
    await prefs.remove(_kPrefRemainingSeconds);
  }

  Future<void> _scheduleEndNotification(
    DateTime endTime, {
    required bool isFocus,
    String? taskTitle,
  }) async {
    final svc = ref.read(notificationServiceProvider);
    if (isFocus) {
      await svc.scheduleSprintEndNotification(
        endTime: endTime,
        taskTitle: taskTitle ?? 'your task',
      );
    } else {
      await svc.scheduleBreakEndNotification(endTime: endTime);
    }
  }

  Future<void> _cancelSprintNotifications() async {
    final svc = ref.read(notificationServiceProvider);
    await svc.cancelSprintNotifications();
  }

  // ---------------------------------------------------------------------------
  // Calculations
  // ---------------------------------------------------------------------------

  static int _calcTotalSprints(int? estimateMinutes) {
    if (estimateMinutes == null || estimateMinutes <= _kSprintMinutes) return 1;
    return (estimateMinutes / _kSprintMinutes).ceil();
  }

  static int _calcSprintNumber(int timeSpentMinutes) {
    return (timeSpentMinutes / _kSprintMinutes).floor() + 1;
  }
}

// ---------------------------------------------------------------------------
// Batching suggestion helpers
// ---------------------------------------------------------------------------

/// Returns the list of micro-tasks from [todayTasks] that collectively fit
/// within a single 20-minute sprint, making them candidates for batching.
///
/// A task is a "micro-task" when its [Todo.timeEstimate] is ≤ 15 minutes.
/// Suggests batching when 2 or more micro-tasks fit within one sprint.
List<Todo> findBatchingCandidates(List<Todo> todayTasks) {
  final microTasks = todayTasks
      .where((t) => t.timeEstimate != null && t.timeEstimate! <= 15)
      .toList();

  if (microTasks.length < 2) return [];

  final totalEstimate =
      microTasks.fold<int>(0, (sum, t) => sum + (t.timeEstimate ?? 0));
  if (totalEstimate > _kSprintMinutes) return [];

  return microTasks;
}
