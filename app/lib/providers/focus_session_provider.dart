import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/todo.dart' show GtdState;
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

  /// Transitions [todoId] to inProgress in the DB and starts the focus timer.
  ///
  /// Throws [StateError] if a different task is already active, preventing
  /// silent session overwrites that leave orphaned inProgress DB rows.
  Future<void> startFocus(String todoId) async {
    if (state.activeTodoId != null && state.activeTodoId != todoId) {
      throw StateError(
        'Cannot start a new focus session while another task is still active.',
      );
    }

    final db = ref.read(databaseProvider);
    final userId = ref.read(currentUserIdProvider);
    final now = DateTime.now();
    await db.todoDao.transitionState(todoId, userId, GtdState.inProgress, now: now);
    state = FocusModeState(
      activeTodoId: todoId,
      sessionStart: now,
    );
  }

  /// Restores a focus session for a task already in inProgress state
  /// (e.g. after app restart). Does not change DB state.
  ///
  /// If the session is currently paused (e.g. user exited via _onExit), the
  /// pause gap is folded into [accumulated] so elapsed stays frozen correctly.
  /// [now] is injectable for deterministic testing; defaults to [DateTime.now].
  void resumeFrom(String todoId, DateTime inProgressSince, {DateTime? now}) {
    if (state.activeTodoId == todoId &&
        state.isPaused &&
        state.pauseStart != null) {
      final pauseDuration = (now ?? DateTime.now()).difference(state.pauseStart!);
      state = FocusModeState(
        activeTodoId: todoId,
        sessionStart: state.sessionStart ?? inProgressSince,
        accumulated: state.accumulated + pauseDuration,
        isPaused: false,
      );
      return;
    }

    state = FocusModeState(
      activeTodoId: todoId,
      sessionStart: inProgressSince,
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

  /// Clears focus session state. The caller is responsible for the DB
  /// state transition (e.g. done) before calling this.
  void endFocus() => state = const FocusModeState();
}

final focusModeProvider =
    NotifierProvider<FocusModeNotifier, FocusModeState>(FocusModeNotifier.new);
