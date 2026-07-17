import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_provider.dart';
import 'database_provider.dart';

class FocusModeState {
  const FocusModeState({
    this.activeTodoId,
    this.sessionStart,
  });

  final String? activeTodoId;

  /// Wall-clock time when the focus segment started.
  final DateTime? sessionStart;

  bool get isActive => activeTodoId != null;

  /// Net elapsed time since the session started.
  Duration get elapsed {
    if (sessionStart == null) return Duration.zero;
    final raw = DateTime.now().difference(sessionStart!);
    return raw.isNegative ? Duration.zero : raw;
  }

  FocusModeState copyWith({
    String? activeTodoId,
    DateTime? sessionStart,
  }) =>
      FocusModeState(
        activeTodoId: activeTodoId ?? this.activeTodoId,
        sessionStart: sessionStart ?? this.sessionStart,
      );
}

class FocusModeNotifier extends Notifier<FocusModeState> {
  @override
  FocusModeState build() => const FocusModeState();

  /// Starts engaging with [todoId]: opens a TimeLog and starts the focus
  /// timer.
  ///
  /// Engagement is independent of FocusSession (ADR-0005): with an open
  /// session, the engagement routes through the session — the Focus pointer
  /// (`current_task_id`) is set and the TimeLog attributes to the session,
  /// whether or not the task is on the Plan. With no session, the TimeLog
  /// is ad hoc (null session FK).
  ///
  /// Throws [StateError] if a different task is already active.
  Future<void> startFocus(String todoId) async {
    // The activeTodoId guard alone leaves a window: state stays inactive
    // until the DB writes below complete, so two concurrent starts could
    // both pass it and both open TimeLogs. The in-flight id closes that
    // window — a duplicate start for the same task defers to the first
    // call; a start for a different task keeps the StateError contract.
    if (_startingTodoId != null) {
      if (_startingTodoId == todoId) return;
      throw StateError(
        'Cannot start a new focus session while another task is still active.',
      );
    }
    if (state.activeTodoId != null && state.activeTodoId != todoId) {
      throw StateError(
        'Cannot start a new focus session while another task is still active.',
      );
    }

    _startingTodoId = todoId;
    try {
      final db = ref.read(databaseProvider);
      final now = DateTime.now();

      final session = await db.focusSessionDao.getActiveSession();
      if (session != null) {
        await db.focusSessionDao.setCurrentTask(
          sessionId: session.id,
          taskId: todoId,
          now: now,
        );
      } else {
        await db.timeLogDao.openLog(
          taskId: todoId,
          userId: ref.read(currentUserIdProvider),
          now: now,
        );
      }
      state = FocusModeState(
        activeTodoId: todoId,
        sessionStart: now,
      );
    } finally {
      _startingTodoId = null;
    }
  }

  /// Task id of the [startFocus] call currently in flight, or null.
  String? _startingTodoId;

  /// Restores a focus session for a task that was already focused before the
  /// app restarted. Does not change DB state.
  ///
  /// [startedAt] should be the time-log's [started_at] so the timer reflects
  /// how long the user has been focused on this specific task.
  void resumeFrom(String todoId, DateTime startedAt, {DateTime? now}) {
    state = FocusModeState(
      activeTodoId: todoId,
      sessionStart: startedAt,
    );
  }

  /// Clears the focused task and resets the timer, closing the open TimeLog
  /// (through the session when one is open; directly for ad-hoc engagement).
  ///
  /// The caller is responsible for any prior DB side-effects (e.g. marking
  /// the task done) before calling this.
  Future<void> endFocus() async {
    final db = ref.read(databaseProvider);
    final session = await db.focusSessionDao.getActiveSession();
    if (session != null) {
      await db.focusSessionDao.setCurrentTask(
        sessionId: session.id,
        taskId: null,
      );
    } else if (state.activeTodoId != null) {
      // Ad-hoc engagement (ADR-0005): no session to close the log through.
      await db.timeLogDao.closeLog(taskId: state.activeTodoId!);
    }
    state = const FocusModeState();
  }
}

final focusModeProvider =
    NotifierProvider<FocusModeNotifier, FocusModeState>(FocusModeNotifier.new);
