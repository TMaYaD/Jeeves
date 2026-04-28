import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_provider.dart';
import 'database_provider.dart';

class FocusModeState {
  const FocusModeState({
    this.activeTodoId,
    this.sessionStart,
    this.accumulated = Duration.zero,
    this.isPaused = false,
    this.pauseStart,
  });

  final String? activeTodoId;

  /// Wall-clock time when the current (unpaused) focus segment started.
  final DateTime? sessionStart;

  /// Total duration subtracted from wall time (accumulated pause gaps).
  final Duration accumulated;

  final bool isPaused;

  /// Wall-clock time when the most recent pause began (null when not paused).
  final DateTime? pauseStart;

  bool get isActive => activeTodoId != null;

  /// Net elapsed time, frozen while paused.
  Duration get elapsed {
    if (sessionStart == null) return Duration.zero;
    if (isPaused && pauseStart != null) {
      return pauseStart!.difference(sessionStart!) - accumulated;
    }
    final raw = DateTime.now().difference(sessionStart!);
    final net = raw - accumulated;
    return net.isNegative ? Duration.zero : net;
  }

  FocusModeState copyWith({
    String? activeTodoId,
    DateTime? sessionStart,
    Duration? accumulated,
    bool? isPaused,
    DateTime? pauseStart,
    bool clearPauseStart = false,
  }) =>
      FocusModeState(
        activeTodoId: activeTodoId ?? this.activeTodoId,
        sessionStart: sessionStart ?? this.sessionStart,
        accumulated: accumulated ?? this.accumulated,
        isPaused: isPaused ?? this.isPaused,
        pauseStart: clearPauseStart ? null : (pauseStart ?? this.pauseStart),
      );
}

class FocusModeNotifier extends Notifier<FocusModeState> {
  @override
  FocusModeState build() => const FocusModeState();

  /// Sets [todoId] as the focused task on the active session and starts the
  /// focus timer.
  ///
  /// Throws [StateError] if a different task is already active, or if no open
  /// session exists (planning must be completed before focusing).
  Future<void> startFocus(String todoId) async {
    if (state.activeTodoId != null && state.activeTodoId != todoId) {
      throw StateError(
        'Cannot start a new focus session while another task is still active.',
      );
    }

    final db = ref.read(databaseProvider);
    final userId = ref.read(currentUserIdProvider);
    final now = DateTime.now();

    final session = await db.focusSessionDao.getActiveSession(userId);
    if (session == null) {
      throw StateError(
        'No active focus session — complete the daily planning ritual first.',
      );
    }

    await db.focusSessionDao.setCurrentTask(
      sessionId: session.id,
      taskId: todoId,
      now: now,
    );
    state = FocusModeState(
      activeTodoId: todoId,
      sessionStart: now,
    );
  }

  /// Restores a focus session for a task that was already focused before the
  /// app restarted. Does not change DB state.
  ///
  /// [startedAt] should be the time-log's [started_at] so the timer reflects
  /// how long the user has been focused on this specific task.
  ///
  /// If the session is currently paused (e.g. user exited via _onExit), the
  /// pause gap is folded into [accumulated] so elapsed stays frozen correctly.
  /// [now] is injectable for deterministic testing; defaults to [DateTime.now].
  void resumeFrom(String todoId, DateTime startedAt, {DateTime? now}) {
    if (state.activeTodoId == todoId &&
        state.isPaused &&
        state.pauseStart != null) {
      final pauseDuration = (now ?? DateTime.now()).difference(state.pauseStart!);
      state = FocusModeState(
        activeTodoId: todoId,
        sessionStart: state.sessionStart ?? startedAt,
        accumulated: state.accumulated + pauseDuration,
        isPaused: false,
      );
      return;
    }

    state = FocusModeState(
      activeTodoId: todoId,
      sessionStart: startedAt,
    );
  }

  /// [now] is injectable for deterministic testing; defaults to [DateTime.now].
  void pauseFocus({DateTime? now}) {
    if (state.isPaused || state.sessionStart == null) return;
    state = state.copyWith(isPaused: true, pauseStart: now ?? DateTime.now());
  }

  /// [now] is injectable for deterministic testing; defaults to [DateTime.now].
  void resumeFocus({DateTime? now}) {
    if (!state.isPaused || state.pauseStart == null) return;
    final pauseDuration = (now ?? DateTime.now()).difference(state.pauseStart!);
    state = FocusModeState(
      activeTodoId: state.activeTodoId,
      sessionStart: state.sessionStart,
      accumulated: state.accumulated + pauseDuration,
      isPaused: false,
    );
  }

  /// Clears the focused task on the active session and resets the timer.
  ///
  /// The caller is responsible for any prior DB side-effects (e.g. marking
  /// the task done) before calling this.
  Future<void> endFocus() async {
    final db = ref.read(databaseProvider);
    final userId = ref.read(currentUserIdProvider);
    final session = await db.focusSessionDao.getActiveSession(userId);
    if (session != null) {
      await db.focusSessionDao.setCurrentTask(
        sessionId: session.id,
        taskId: null,
      );
    }
    state = const FocusModeState();
  }
}

final focusModeProvider =
    NotifierProvider<FocusModeNotifier, FocusModeState>(FocusModeNotifier.new);
