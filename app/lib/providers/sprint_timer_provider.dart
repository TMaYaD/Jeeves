/// Pomodoro sprint timer state and notifier (Issue #47).
///
/// Implements a configurable focus sprint + break cycle bound to a selected
/// Focus Mode task. Durations are read from [focusSettingsProvider] at sprint-
/// start time. Timer state persists to SharedPreferences across app backgrounding;
/// a local notification fires at expiry even when the app is in the background.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/gtd_database.dart';
import '../services/notification_service.dart';
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
const _kPrefOvertimeStartMs = 'sprint_overtime_start_ms';

// Phase string values stored in SharedPreferences.
const _kPhaseFocus = 'focus';
const _kPhaseBreak = 'break';
const _kPhaseFocusOvertime = 'focus_overtime';
const _kPhaseBreakOvertime = 'break_overtime';

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
    this.overtime = Duration.zero,
    this.isPaused = false,
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
        overtime: overtime ?? this.overtime,
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
  int? _overtimeStartMs;

  @override
  SprintTimerState build() {
    ref.onDispose(() => _ticker?.cancel());
    // Fire-and-forget: runs async without blocking build(). State emitted
    // inside _restoreFromPrefs() triggers a widget rebuild when ready.
    _restoreFromPrefs();
    return const SprintTimerState();
  }

  // ---------------------------------------------------------------------------
  // Convenience getters for current configured durations (fallback only;
  // startSprint reads from SharedPreferences directly to avoid async race).
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

      // Read from SharedPreferences directly to avoid the async-load race in
      // focusSettingsProvider: its build() fires _loadFromPrefs() async, so
      // ref.read may return stale defaults if called before it completes.
      final prefs = await SharedPreferences.getInstance();
      final sm = prefs.getInt(kFocusSprintDurationMinutesPrefKey) ?? _sprintMinutes;
      final bm = prefs.getInt(kFocusBreakDurationMinutesPrefKey) ?? _breakMinutes;
      final sprintDur = Duration(minutes: sm);

      final totalSprints = _calcTotalSprints(task.timeEstimate, sm);
      final totalMinutes = await ref
          .read(databaseProvider)
          .timeLogDao
          .totalMinutesForTask(task.id);
      final sprintNumber = _calcSprintNumber(totalMinutes, sm);
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

  /// Pauses the sprint by entering a break early (works from focus or focusOvertime).
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

  /// Resumes a paused timer (legacy path, not used by the redesigned UI).
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

  /// Stops the sprint and returns to idle. The open time log is closed by
  /// [FocusSessionDao.setCurrentTask] when [FocusModeNotifier.endFocus] is called.
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
      await _startBreak();
    } finally {
      if (state.isProcessing) state = state.copyWith(isProcessing: false);
    }
  }

  /// Skips the break and starts the next sprint immediately (works from break_ or breakOvertime).
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

    final phase = switch (phaseStr) {
      _kPhaseBreak => SprintPhase.break_,
      _kPhaseFocusOvertime => SprintPhase.focusOvertime,
      _kPhaseBreakOvertime => SprintPhase.breakOvertime,
      _ => SprintPhase.focus,
    };

    // Overtime phases: restore elapsed overtime, resume ticker if not maxed.
    if (phase == SprintPhase.focusOvertime || phase == SprintPhase.breakOvertime) {
      final total = phase == SprintPhase.focusOvertime
          ? Duration(minutes: sm)
          : Duration(minutes: bm);
      final savedMs = prefs.getInt(_kPrefOvertimeStartMs);
      Duration overtime;
      if (savedMs != null) {
        _overtimeStartMs = savedMs;
        overtime = DateTime.now()
            .difference(DateTime.fromMillisecondsSinceEpoch(savedMs));
        if (overtime > total) overtime = total;
      } else {
        overtime = total;
      }
      state = SprintTimerState(
        phase: phase,
        activeTaskId: activeTaskId,
        activeTaskTitle: taskTitle,
        sprintNumber: sprintNumber,
        totalSprints: totalSprints,
        remaining: Duration.zero,
        total: total,
        overtime: overtime,
        sprintDurationMinutes: sm,
        breakDurationMinutes: bm,
        lastBreakEndedAt: lastBreakEndedAt,
      );
      if (overtime < total) _startTicker();
      return;
    }

    // Countdown phases.
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
      // Time is tracked via TimeLog; no explicit logging needed here.
      final focusEndedAt = _endTime;
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
    } else {
      // Break expired in background — record it and go idle.
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
      overtime: Duration.zero,
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
    _overtimeStartMs = null;
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

  void _startFocusOvertime() {
    _overtimeStartMs = DateTime.now().millisecondsSinceEpoch;
    state = state.copyWith(
      phase: SprintPhase.focusOvertime,
      remaining: Duration.zero,
      overtime: Duration.zero,
    );
    _persistOvertimeStart();
    _startTicker();
  }

  void _startBreakOvertime() {
    _overtimeStartMs = DateTime.now().millisecondsSinceEpoch;
    state = state.copyWith(
      phase: SprintPhase.breakOvertime,
      remaining: Duration.zero,
      overtime: Duration.zero,
    );
    _persistOvertimeStart();
    _startTicker();
  }

  Future<void> _persistOvertimeStart() async {
    if (_overtimeStartMs == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kPrefOvertimeStartMs, _overtimeStartMs!);
    await prefs.setString(_kPrefPhase,
        state.phase == SprintPhase.focusOvertime
            ? _kPhaseFocusOvertime
            : _kPhaseBreakOvertime);
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    if (state.isOvertime) {
      if (_overtimeStartMs == null) return;
      final overtime = DateTime.now().difference(
          DateTime.fromMillisecondsSinceEpoch(_overtimeStartMs!));
      if (overtime >= state.total) {
        _ticker?.cancel();
        state = state.copyWith(overtime: state.total);
        return;
      }
      state = state.copyWith(overtime: overtime);
      return;
    }
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
    if (state.phase == SprintPhase.focus) {
      // Countdown ended: wait in overtime (no auto-break).
      // Time is tracked via TimeLog; FocusSessionDao.setCurrentTask closes it.
      _startFocusOvertime();
    } else if (state.phase == SprintPhase.break_) {
      // Break ended: wait in overtime (no auto-sprint).
      _startBreakOvertime();
    }
  }

  Future<void> _persist({required bool isPaused}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPrefActiveTaskId, state.activeTaskId ?? '');
    await prefs.setString(_kPrefActiveTaskTitle, state.activeTaskTitle ?? '');
    await prefs.setString(_kPrefEndTime, _endTime?.toIso8601String() ?? '');
    final phaseStr = switch (state.phase) {
      SprintPhase.focus => _kPhaseFocus,
      SprintPhase.focusOvertime => _kPhaseFocusOvertime,
      SprintPhase.break_ => _kPhaseBreak,
      SprintPhase.breakOvertime => _kPhaseBreakOvertime,
      SprintPhase.idle => _kPhaseFocus,
    };
    await prefs.setString(_kPrefPhase, phaseStr);
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
    await prefs.remove(_kPrefOvertimeStartMs);
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
