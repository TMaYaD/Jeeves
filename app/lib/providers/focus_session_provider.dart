import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    final now = DateTime.now();

    final session = await db.focusSessionDao.getActiveSession();
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
  void resumeFrom(String todoId, DateTime startedAt, {DateTime? now}) {
    state = FocusModeState(
      activeTodoId: todoId,
      sessionStart: startedAt,
    );
  }

  /// Clears the focused task on the active session and resets the timer.
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
    }
    state = const FocusModeState();
  }
}

final focusModeProvider =
    NotifierProvider<FocusModeNotifier, FocusModeState>(FocusModeNotifier.new);
