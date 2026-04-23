/// Pomodoro sprint timer state and notifier (Issue #47).
///
/// Implements a 20-minute focus sprint + 3-minute break cycle bound to a
/// selected Focus Mode task. Timer state is persisted to SharedPreferences so
/// it survives app backgrounding; a local notification fires at expiry even
/// when the app is in the background.
library;

import 'dart:async';

import 'package:drift/drift.dart'
    show CustomExpression, Expression, RawValuesInsertable, Variable;
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
  final bool isProcessing;

  const SprintTimerState({
    this.phase = SprintPhase.idle,
    this.activeTaskId,
    this.activeTaskTitle,
    this.sprintNumber = 1,
    this.totalSprints = 1,
    this.remaining = _kSprintDuration,
    this.total = _kSprintDuration,
    this.isPaused = false,
    this.isProcessing = false,
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
    bool? isProcessing,
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
        isProcessing: isProcessing ?? this.isProcessing,
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
    // Fire-and-forget: runs async without blocking build(). State emitted
    // inside _restoreFromPrefs() triggers a widget rebuild when ready.
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
    if (!state.isActive || state.isPaused || state.isProcessing) return;
    state = state.copyWith(isProcessing: true);
    try {
      _ticker?.cancel();
      HapticFeedback.lightImpact();

      state = state.copyWith(isPaused: true, isProcessing: false);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kPrefIsPaused, true);
      await prefs.setInt(_kPrefRemainingSeconds, state.remaining.inSeconds);
      await _cancelSprintNotifications();
    } finally {
      if (state.isProcessing) state = state.copyWith(isProcessing: false);
    }
  }

  /// Resumes a paused timer.
  Future<void> resumeSprint() async {
    if (!state.isActive || !state.isPaused || state.isProcessing) return;
    state = state.copyWith(isProcessing: true);
    try {
      HapticFeedback.lightImpact();

      _endTime = DateTime.now().add(state.remaining);
      state = state.copyWith(isPaused: false, isProcessing: false);
      await _persist(isPaused: false);
      await _scheduleEndNotification(
        _endTime!,
        isFocus: state.isFocus,
        taskTitle: state.activeTaskTitle,
      );
      _startTicker();
    } finally {
      if (state.isProcessing) state = state.copyWith(isProcessing: false);
    }
  }

  /// Stops the sprint entirely, returning to idle.
  Future<void> stopSprint() async {
    if (state.isProcessing) return;
    state = state.copyWith(isProcessing: true);
    try {
      _ticker?.cancel();
      HapticFeedback.mediumImpact();
      await _cancelSprintNotifications();
      await _clearPrefs();
      state = const SprintTimerState();
    } finally {
      if (state.isProcessing) state = state.copyWith(isProcessing: false);
    }
  }

  /// Records a completed sprint, logs time to the task, then starts the break.
  Future<void> completeSprint() async {
    if (state.isProcessing) return;
    state = state.copyWith(isProcessing: true);
    try {
      _ticker?.cancel();
      HapticFeedback.heavyImpact();
      await _cancelSprintNotifications();
      await _logSprintTimeToTask();
      await _startBreak();
    } finally {
      if (state.isProcessing) state = state.copyWith(isProcessing: false);
    }
  }

  /// Skips the break timer and returns to idle.
  Future<void> skipBreak() async {
    if (state.isProcessing) return;
    state = state.copyWith(isProcessing: true);
    try {
      _ticker?.cancel();
      HapticFeedback.lightImpact();
      await _cancelSprintNotifications();
      await _clearPrefs();
      state = const SprintTimerState();
    } finally {
      if (state.isProcessing) state = state.copyWith(isProcessing: false);
    }
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
      // Compute break window relative to when the sprint actually ended so
      // reopening the app 10+ minutes later doesn't grant a fresh full break.
      final focusEndedAt = _endTime;
      _logSprintTimeToTask().then((_) {
        if (focusEndedAt != null) {
          final breakEndTime = focusEndedAt.add(_kBreakDuration);
          final remainingBreak = breakEndTime.difference(DateTime.now());
          if (remainingBreak <= Duration.zero) {
            _clearPrefs();
            state = const SprintTimerState();
            return;
          }
          _startBreak(endTime: breakEndTime, remaining: remainingBreak);
        } else {
          _startBreak();
        }
      });
    } else {
      _clearPrefs();
      state = const SprintTimerState();
    }
  }

  Future<void> _startBreak({DateTime? endTime, Duration? remaining}) async {
    _endTime = endTime ?? DateTime.now().add(_kBreakDuration);
    final breakRemaining = remaining ?? _kBreakDuration;
    state = state.copyWith(
      phase: SprintPhase.break_,
      remaining: breakRemaining,
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
      // Single atomic SQL increment — avoids a read-modify-write race on
      // offline-first tables where a sync write could land between SELECT and UPDATE.
      await (db.update(db.todos)
            ..where((t) => Expression.and([t.id.equals(taskId), t.userId.equals(userId)])))
          .write(RawValuesInsertable({
        'time_spent_minutes': const CustomExpression<int>(
            'coalesce(time_spent_minutes, 0) + $_kSprintMinutes'),
        'updated_at': Variable(DateTime.now()),
      }));
    } catch (_) {
      // Non-fatal: time tracking is best-effort.
    }
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
      .toList()
    ..sort((a, b) => (a.timeEstimate ?? 0).compareTo(b.timeEstimate ?? 0));

  if (microTasks.length < 2) return [];

  // Greedy accumulation (smallest-first) so we find the largest subset that
  // fits in one sprint rather than requiring *all* micro-tasks to fit.
  var budget = 0;
  final candidates = <Todo>[];
  for (final task in microTasks) {
    final est = task.timeEstimate ?? 0;
    if (budget + est <= _kSprintMinutes) {
      budget += est;
      candidates.add(task);
    }
  }

  return candidates.length >= 2 ? candidates : [];
}
