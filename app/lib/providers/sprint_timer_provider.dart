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
const _kPrefIsPaused = 'sprint_is_paused'; // legacy key, kept for prefs cleanup
const _kPrefRemainingSeconds = 'sprint_remaining_seconds'; // legacy key, kept for prefs cleanup
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

  /// Bumped by [stopSprint]. Every other transition captures it on entry and
  /// re-checks after each await via [_superseded], so an operation that was
  /// already in flight when a stop landed cannot write state, re-persist the
  /// sprint or restart the ticker afterwards. See [stopSprint] for why it
  /// cannot simply refuse to run while another transition holds the floor.
  int _stopGeneration = 0;

  /// Whether a [stopSprint] has landed since [gen] was captured — meaning the
  /// caller is finishing work about a sprint that no longer exists and must
  /// abandon it rather than write.
  bool _superseded(int gen) => gen != _stopGeneration;

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
    final gen = _stopGeneration;
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
      // Two awaits happened above; a stop may have landed while they ran.
      if (_superseded(gen)) return;
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

      await _persist();
      // A stop cancels pending notifications, so one scheduled after it
      // outlives the sprint it belongs to.
      if (_superseded(gen)) return;
      await _scheduleEndNotification(
          _endTime!, isFocus: true, taskTitle: task.title);
      // Re-check before arming the ticker: a stop during the awaits above has
      // already cancelled it, and starting it again here would leave it
      // ticking on a sprint that is over. A stop landing mid-schedule also
      // cancels nothing, so undo the late notification too (see [_startBreak]).
      if (_superseded(gen)) {
        await _cancelSprintNotifications();
        return;
      }
      _startTicker();
    } finally {
      // Only the owning transition clears the flag. A superseded one bailing
      // out here would otherwise clear an `isProcessing` that the [stopSprint]
      // which superseded it had set and still owns.
      if (!_superseded(gen) && state.isProcessing) {
        state = state.copyWith(isProcessing: false);
      }
    }
  }

  /// Ends the current sprint early and starts a break.
  Future<void> startBreak() async {
    if (!state.isFocus || state.isProcessing) return;
    final gen = _stopGeneration;
    state = state.copyWith(isProcessing: true);
    try {
      _ticker?.cancel();
      HapticFeedback.lightImpact();
      await _cancelSprintNotifications();
      if (_superseded(gen)) return;
      state = state.copyWith(isProcessing: false);
      await _startBreak(gen: gen);
    } finally {
      // Only the owning transition clears the flag. A superseded one bailing
      // out here would otherwise clear an `isProcessing` that the [stopSprint]
      // which superseded it had set and still owns.
      if (!_superseded(gen) && state.isProcessing) {
        state = state.copyWith(isProcessing: false);
      }
    }
  }

  /// Stops the sprint and returns to idle. The open time log is closed by
  /// [FocusSessionDao.setCurrentTask] when [FocusModeNotifier.endFocus] is called.
  /// Stopping is terminal, which makes it the one transition that must always
  /// run to completion. Three things follow, each of which used to be wrong:
  ///
  /// - **No `isProcessing` early-return.** The other transitions bail when one
  ///   is already in flight, but a stop that bails is a silent no-op its caller
  ///   cannot tell apart from a successful stop — so the missing-task teardown
  ///   would report the sprint ended and clear focus mode while it kept
  ///   running. A stop issued mid-operation wins instead.
  /// - **The two cleanups are attempted independently.** Chaining them let the
  ///   less important failure suppress the one that matters: a notification
  ///   channel throwing would skip `_clearPrefs`, leaving the sprint on disk
  ///   for `_restoreFromPrefs` to resurrect on the next launch.
  /// - **The local reset is unconditional.** It used to sit after both awaits,
  ///   so a throw left the state reporting `isActive` — a sprint the UI still
  ///   counted as running with nothing able to stop it, since every stop
  ///   control lives behind an active focus mode the caller has usually just
  ///   cleared.
  ///
  /// The first failure still propagates, so callers that report teardown
  /// failure keep doing so; what changes is that they no longer report it *and*
  /// strand a phantom sprint.
  Future<void> stopSprint() async {
    // Supersede every transition currently in flight. Without the
    // `isProcessing` early-return, a stop can now interleave with one — and a
    // transition resumes after its awaits holding values computed before the
    // stop, so it would happily re-arm the ticker and re-persist the sprint it
    // was told to abandon, resurrecting it on the next launch. Bumping the
    // generation makes every such resumption a no-op; see [_superseded].
    _stopGeneration++;
    state = state.copyWith(isProcessing: true);
    _ticker?.cancel();
    HapticFeedback.mediumImpact();
    Object? firstError;
    StackTrace? firstStack;
    try {
      await _cancelSprintNotifications();
    } catch (e, s) {
      firstError = e;
      firstStack = s;
    }
    try {
      await _clearPrefs();
    } catch (e, s) {
      firstError ??= e;
      firstStack ??= s;
    }
    state = const SprintTimerState();
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack!);
    }
  }

  /// Records a completed sprint, logs time to the task, then starts the break.
  Future<void> completeSprint() async {
    if (state.isProcessing) return;
    final gen = _stopGeneration;
    state = state.copyWith(isProcessing: true);
    try {
      _ticker?.cancel();
      HapticFeedback.heavyImpact();
      await _cancelSprintNotifications();
      if (_superseded(gen)) return;
      await _startBreak(gen: gen);
    } finally {
      // Only the owning transition clears the flag. A superseded one bailing
      // out here would otherwise clear an `isProcessing` that the [stopSprint]
      // which superseded it had set and still owns.
      if (!_superseded(gen) && state.isProcessing) {
        state = state.copyWith(isProcessing: false);
      }
    }
  }

  /// Skips the break and starts the next sprint immediately (works from break_ or breakOvertime).
  Future<void> skipBreak() async {
    if (!state.isBreak || state.isProcessing) return;
    final gen = _stopGeneration;
    state = state.copyWith(isProcessing: true);
    try {
      _ticker?.cancel();
      HapticFeedback.lightImpact();
      await _cancelSprintNotifications();
      if (_superseded(gen)) return;
      final now = DateTime.now();
      await _persistLastBreakEndedAt(now);
      if (_superseded(gen)) return;
      state = state.copyWith(isProcessing: false, lastBreakEndedAt: now);
      await _startNextSprint(gen: gen);
    } finally {
      // Only the owning transition clears the flag. A superseded one bailing
      // out here would otherwise clear an `isProcessing` that the [stopSprint]
      // which superseded it had set and still owns.
      if (!_superseded(gen) && state.isProcessing) {
        state = state.copyWith(isProcessing: false);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  Future<void> _restoreFromPrefs() async {
    // `build()` fires this without awaiting it, so a stop issued during the
    // first frames can land while the prefs read is in flight — after which
    // restoring would put back the very sprint that was just cleared.
    final gen = _stopGeneration;
    final prefs = await SharedPreferences.getInstance();
    if (_superseded(gen)) return;
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

    _endTime = DateTime.tryParse(endTimeStr);
    if (_endTime == null) return;
    final remaining = _endTime!.difference(DateTime.now());
    if (remaining.isNegative) {
      _onTimerExpiredBackground(phase, sm: sm, bm: bm,
          lastBreakEndedAt: lastBreakEndedAt);
      return;
    }

    state = SprintTimerState(
      phase: phase,
      activeTaskId: activeTaskId,
      activeTaskTitle: taskTitle,
      sprintNumber: sprintNumber,
      totalSprints: totalSprints,
      remaining: remaining,
      total: total,
      sprintDurationMinutes: sm,
      breakDurationMinutes: bm,
      lastBreakEndedAt: lastBreakEndedAt,
    );

    _startTicker();
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

  /// [gen] threads the caller's [_stopGeneration] through, so a stop that lands
  /// mid-break-start cannot be undone by this method re-persisting the break
  /// after it. Defaults to the current generation for the restore path, which
  /// runs before any transition is in flight.
  Future<void> _startBreak({
    DateTime? endTime,
    Duration? remaining,
    int? sm,
    int? bm,
    DateTime? lastBreakEndedAt,
    int? gen,
  }) async {
    final g = gen ?? _stopGeneration;
    if (_superseded(g)) return;
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
      sprintDurationMinutes: sprintMin,
      breakDurationMinutes: breakMin,
    );
    final prefs = await SharedPreferences.getInstance();
    // A stop between the state write above and this persist would otherwise be
    // undone on disk — the sprint would be gone from memory but back on the
    // next launch.
    if (_superseded(g)) return;
    await prefs.setString(_kPrefEndTime, _endTime!.toIso8601String());
    await prefs.setString(_kPrefPhase, _kPhaseBreak);
    // Checked either side of the schedule. Before, because a stop already
    // landed means there is nothing to schedule for. After, because the stop
    // may land *while* this call is in flight — its cancellation then runs
    // against a notification that does not exist yet, and the schedule lands
    // afterwards, outliving the sprint it belongs to. The OS would fire
    // "break over" for a break that was stopped, so the superseded transition
    // cleans up the one side effect only it knows it created.
    if (_superseded(g)) return;
    await _scheduleEndNotification(_endTime!, isFocus: false);
    if (_superseded(g)) {
      await _cancelSprintNotifications();
      return;
    }
    _startTicker();
  }

  /// [gen] threads the caller's generation through — see [_startBreak].
  Future<void> _startNextSprint({int? gen}) async {
    final g = gen ?? _stopGeneration;
    if (_superseded(g)) return;
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
    await _persist();
    // See [_startBreak]: a notification scheduled after a stop outlives the
    // sprint it belongs to.
    if (_superseded(g)) return;
    await _scheduleEndNotification(
      _endTime!,
      isFocus: true,
      taskTitle: state.activeTaskTitle ?? '',
    );
    // See [_startBreak]: a stop landing mid-schedule cancels nothing, so the
    // superseded transition undoes its own late notification.
    if (_superseded(g)) {
      await _cancelSprintNotifications();
      return;
    }
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

  Future<void> _persist() async {
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
