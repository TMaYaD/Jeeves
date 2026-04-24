/// Pomodoro sprint timer state and notifier (Issue #47).
///
/// Implements a configurable focus sprint + break cycle bound to a selected
/// Focus Mode task. Durations are read from [focusSettingsProvider] at sprint-
/// start time. Timer state persists to SharedPreferences across app backgrounding;
/// a local notification fires at expiry even when the app is in the background.
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
import 'focus_settings_provider.dart';

// ---------------------------------------------------------------------------
// SharedPreferences keys
// ---------------------------------------------------------------------------

const _kPrefActiveTaskId = 'sprint_active_task_id';
const _kPrefActiveTaskTitle = 'sprint_active_task_title';
const _kPrefEndTime = 'sprint_end_time';
const _kPrefPhase = 'sprint_phase';
const _kPrefSprintNumber = 'sprint_sprint_number';
const _kPrefTotalSprints = 'sprint_total_sprints';
const _kPrefIsPaused = 'sprint_is_paused';
const _kPrefRemainingSeconds = 'sprint_remaining_seconds';
const _kPrefSprintMinutes = 'sprint_sprint_duration_minutes';
const _kPrefBreakMinutes = 'sprint_break_duration_minutes';
const _kPrefLastBreakEndedAt = 'sprint_last_break_ended_at';

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
    this.isPaused = false,
    this.isProcessing = false,
    this.sprintDurationMinutes = 20,
    this.breakDurationMinutes = 3,
    this.lastBreakEndedAt,
  });

  bool get isActive => phase != SprintPhase.idle;
  bool get isFocus => phase == SprintPhase.focus;
  bool get isBreak => phase == SprintPhase.break_;

  /// 0.0 → 1.0, where 1.0 means the timer has fully elapsed.
  double get progress {
    if (total.inSeconds == 0) return 0;
    return 1 - (remaining.inSeconds / total.inSeconds);
  }

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
    bool? isPaused,
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
        isPaused: isPaused ?? this.isPaused,
        isProcessing: isProcessing ?? this.isProcessing,
        sprintDurationMinutes:
            sprintDurationMinutes ?? this.sprintDurationMinutes,
        breakDurationMinutes: breakDurationMinutes ?? this.breakDurationMinutes,
        lastBreakEndedAt: lastBreakEndedAt ?? this.lastBreakEndedAt,
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
  // Convenience getters for current configured durations
  // ---------------------------------------------------------------------------

  int get _sprintMinutes =>
      ref.read(focusSettingsProvider).sprintDurationMinutes;
  int get _breakMinutes => ref.read(focusSettingsProvider).breakDurationMinutes;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Starts a focus sprint for [task] using the currently configured durations.
  Future<void> startSprint(Todo task) async {
    if (state.isProcessing) return;
    state = state.copyWith(isProcessing: true);
    try {
      _ticker?.cancel();
      HapticFeedback.mediumImpact();

      final sm = _sprintMinutes;
      final bm = _breakMinutes;
      final sprintDur = Duration(minutes: sm);

      final totalSprints = _calcTotalSprints(task.timeEstimate, sm);
      final sprintNumber = _calcSprintNumber(task.timeSpentMinutes, sm);
      _endTime = DateTime.now().add(sprintDur);

      // Carry forward lastBreakEndedAt so post-break cooldown survives
      // starting a new sprint immediately after a break.
      state = SprintTimerState(
        phase: SprintPhase.focus,
        activeTaskId: task.id,
        activeTaskTitle: task.title,
        sprintNumber: sprintNumber,
        totalSprints: totalSprints,
        remaining: sprintDur,
        total: sprintDur,
        sprintDurationMinutes: sm,
        breakDurationMinutes: bm,
        lastBreakEndedAt: state.lastBreakEndedAt,
      );

      await _persist(isPaused: false);
      await _scheduleEndNotification(
          _endTime!, isFocus: true, taskTitle: task.title);
      _startTicker();
    } finally {
      if (state.isProcessing) state = state.copyWith(isProcessing: false);
    }
  }

  /// Pauses the sprint by entering a break early.
  Future<void> pauseSprint() async {
    if (!state.isFocus || state.isProcessing) return;
    state = state.copyWith(isProcessing: true);
    try {
      _ticker?.cancel();
      HapticFeedback.lightImpact();
      await _cancelSprintNotifications();
      state = state.copyWith(isProcessing: false);
      await _startBreak();
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

  /// Stops the sprint entirely, returning to idle. Does not record a break end.
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

  /// Skips the break and starts the next sprint immediately.
  Future<void> skipBreak() async {
    if (!state.isBreak || state.isProcessing) return;
    state = state.copyWith(isProcessing: true);
    try {
      _ticker?.cancel();
      HapticFeedback.lightImpact();
      await _cancelSprintNotifications();
      final now = DateTime.now();
      await _persistLastBreakEndedAt(now);
      state = state.copyWith(isProcessing: false, lastBreakEndedAt: now);
      await _startNextSprint();
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

    // Restore lastBreakEndedAt regardless of whether a sprint is active.
    final lastBreakStr = prefs.getString(_kPrefLastBreakEndedAt);
    final lastBreakEndedAt =
        lastBreakStr != null ? DateTime.tryParse(lastBreakStr) : null;

    if (activeTaskId == null || activeTaskId.isEmpty) {
      if (lastBreakEndedAt != null) {
        // No active sprint but there was a recent break — carry the cooldown.
        final sm = prefs.getInt(_kPrefSprintMinutes) ?? 20;
        final bm = prefs.getInt(_kPrefBreakMinutes) ?? 3;
        state = SprintTimerState(
          sprintDurationMinutes: sm,
          breakDurationMinutes: bm,
          lastBreakEndedAt: lastBreakEndedAt,
        );
      }
      return;
    }

    final endTimeStr = prefs.getString(_kPrefEndTime);
    final phaseStr = prefs.getString(_kPrefPhase);
    if (endTimeStr == null || phaseStr == null) return;

    final sprintNumber = prefs.getInt(_kPrefSprintNumber) ?? 1;
    final totalSprints = prefs.getInt(_kPrefTotalSprints) ?? 1;
    final isPaused = prefs.getBool(_kPrefIsPaused) ?? false;
    final remainingSeconds = prefs.getInt(_kPrefRemainingSeconds);
    final taskTitle = prefs.getString(_kPrefActiveTaskTitle) ?? '';
    final sm = prefs.getInt(_kPrefSprintMinutes) ?? 20;
    final bm = prefs.getInt(_kPrefBreakMinutes) ?? 3;

    final phase =
        phaseStr == _kPhaseBreak ? SprintPhase.break_ : SprintPhase.focus;
    final total = phase == SprintPhase.focus
        ? Duration(minutes: sm)
        : Duration(minutes: bm);

    Duration remaining;
    if (isPaused && remainingSeconds != null) {
      remaining = Duration(seconds: remainingSeconds);
    } else {
      _endTime = DateTime.tryParse(endTimeStr);
      if (_endTime == null) return;
      remaining = _endTime!.difference(DateTime.now());
      if (remaining.isNegative) {
        _onTimerExpiredBackground(phase, sm: sm, bm: bm,
            lastBreakEndedAt: lastBreakEndedAt);
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
      sprintDurationMinutes: sm,
      breakDurationMinutes: bm,
      lastBreakEndedAt: lastBreakEndedAt,
    );

    if (!isPaused) _startTicker();
  }

  void _onTimerExpiredBackground(SprintPhase expiredPhase,
      {required int sm, required int bm, DateTime? lastBreakEndedAt}) {
    if (expiredPhase == SprintPhase.focus) {
      // Compute break window relative to when the sprint actually ended so
      // reopening the app 10+ minutes later doesn't grant a fresh full break.
      final focusEndedAt = _endTime;
      _logSprintTimeToTask().then((_) {
        if (focusEndedAt != null) {
          final breakEndTime = focusEndedAt.add(Duration(minutes: bm));
          final remainingBreak = breakEndTime.difference(DateTime.now());
          if (remainingBreak <= Duration.zero) {
            _clearPrefs();
            final now = DateTime.now();
            _persistLastBreakEndedAt(now);
            state = SprintTimerState(
              sprintDurationMinutes: sm,
              breakDurationMinutes: bm,
              lastBreakEndedAt: now,
            );
            return;
          }
          _startBreak(
              endTime: breakEndTime,
              remaining: remainingBreak,
              sm: sm,
              bm: bm,
              lastBreakEndedAt: lastBreakEndedAt);
        } else {
          _startBreak(sm: sm, bm: bm, lastBreakEndedAt: lastBreakEndedAt);
        }
      });
    } else {
      // Break expired in background — record it.
      _clearPrefs();
      final now = DateTime.now();
      _persistLastBreakEndedAt(now);
      state = SprintTimerState(
        sprintDurationMinutes: sm,
        breakDurationMinutes: bm,
        lastBreakEndedAt: now,
      );
    }
  }

  Future<void> _startBreak({
    DateTime? endTime,
    Duration? remaining,
    int? sm,
    int? bm,
    DateTime? lastBreakEndedAt,
  }) async {
    final breakMin = bm ?? state.breakDurationMinutes;
    final sprintMin = sm ?? state.sprintDurationMinutes;
    final breakDur = Duration(minutes: breakMin);
    _endTime = endTime ?? DateTime.now().add(breakDur);
    final breakRemaining = remaining ?? breakDur;
    state = state.copyWith(
      phase: SprintPhase.break_,
      remaining: breakRemaining,
      total: breakDur,
      isPaused: false,
      sprintDurationMinutes: sprintMin,
      breakDurationMinutes: breakMin,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPrefEndTime, _endTime!.toIso8601String());
    await prefs.setString(_kPrefPhase, _kPhaseBreak);
    await prefs.setBool(_kPrefIsPaused, false);
    await _scheduleEndNotification(_endTime!, isFocus: false);
    _startTicker();
  }

  Future<void> _startNextSprint() async {
    final sm = state.sprintDurationMinutes;
    final bm = state.breakDurationMinutes;
    final sprintDur = Duration(minutes: sm);
    final nextNumber = state.sprintNumber + 1;
    final total = nextNumber > state.totalSprints ? nextNumber : state.totalSprints;
    _endTime = DateTime.now().add(sprintDur);
    state = SprintTimerState(
      phase: SprintPhase.focus,
      activeTaskId: state.activeTaskId,
      activeTaskTitle: state.activeTaskTitle,
      sprintNumber: nextNumber,
      totalSprints: total,
      remaining: sprintDur,
      total: sprintDur,
      sprintDurationMinutes: sm,
      breakDurationMinutes: bm,
      lastBreakEndedAt: state.lastBreakEndedAt,
    );
    await _persist(isPaused: false);
    await _scheduleEndNotification(
      _endTime!,
      isFocus: true,
      taskTitle: state.activeTaskTitle ?? '',
    );
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
      // Break ended naturally — record timestamp and start next sprint.
      final now = DateTime.now();
      _persistLastBreakEndedAt(now);
      state = state.copyWith(lastBreakEndedAt: now);
      _startNextSprint();
    }
  }

  Future<void> _logSprintTimeToTask() async {
    final taskId = state.activeTaskId;
    if (taskId == null) return;
    final sprintMin = state.sprintDurationMinutes;
    try {
      final db = ref.read(databaseProvider);
      final userId = ref.read(currentUserIdProvider);
      // Single atomic SQL increment — avoids a read-modify-write race on
      // offline-first tables where a sync write could land between SELECT and UPDATE.
      await (db.update(db.todos)
            ..where((t) => Expression.and(
                [t.id.equals(taskId), t.userId.equals(userId)])))
          .write(RawValuesInsertable({
        'time_spent_minutes': CustomExpression<int>(
            'coalesce(time_spent_minutes, 0) + $sprintMin'),
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
    await prefs.setInt(_kPrefSprintMinutes, state.sprintDurationMinutes);
    await prefs.setInt(_kPrefBreakMinutes, state.breakDurationMinutes);
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
    await prefs.remove(_kPrefSprintMinutes);
    await prefs.remove(_kPrefBreakMinutes);
    // _kPrefLastBreakEndedAt is intentionally NOT cleared here — it persists
    // across sprint resets so the post-break cooldown survives idle state.
  }

  Future<void> _persistLastBreakEndedAt(DateTime t) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPrefLastBreakEndedAt, t.toIso8601String());
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

  static int _calcTotalSprints(int? estimateMinutes, int sprintMinutes) {
    if (estimateMinutes == null || estimateMinutes <= sprintMinutes) return 1;
    return (estimateMinutes / sprintMinutes).ceil();
  }

  static int _calcSprintNumber(int timeSpentMinutes, int sprintMinutes) {
    return (timeSpentMinutes / sprintMinutes).floor() + 1;
  }
}

// ---------------------------------------------------------------------------
// Batching suggestion helpers
// ---------------------------------------------------------------------------

/// Returns micro-tasks from [todayTasks] that collectively fit in one sprint.
///
/// Micro-tasks have [Todo.timeEstimate] ≤ 15 min. Batching is suggested when
/// 2+ micro-tasks fit within [sprintMinutes] (default 20).
List<Todo> findBatchingCandidates(List<Todo> todayTasks,
    {int sprintMinutes = 20}) {
  final microTasks = todayTasks
      .where((t) => t.timeEstimate != null && t.timeEstimate! <= 15)
      .toList()
    ..sort((a, b) => (a.timeEstimate ?? 0).compareTo(b.timeEstimate ?? 0));

  if (microTasks.length < 2) return [];

  // Greedy accumulation (smallest-first) — finds the largest subset that fits
  // in one sprint rather than requiring *all* micro-tasks to fit.
  var budget = 0;
  final candidates = <Todo>[];
  for (final task in microTasks) {
    final est = task.timeEstimate ?? 0;
    if (budget + est <= sprintMinutes) {
      budget += est;
      candidates.add(task);
    }
  }

  return candidates.length >= 2 ? candidates : [];
}
