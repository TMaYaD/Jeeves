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
    // both pass it and both open TimeLogs. The in-flight transition closes
    // that window — a duplicate start for the same task awaits the first
    // call's transition (observing its completion or error); a start for a
    // different task keeps the StateError contract.
    final inFlight = _startFocusInFlight;
    if (inFlight != null) {
      if (_startingTodoId == todoId) return inFlight;
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
    final transition = _startFocusTransition(todoId);
    _startFocusInFlight = transition;
    try {
      await transition;
    } finally {
      _startingTodoId = null;
      _startFocusInFlight = null;
    }
  }

  /// The DB transition of [startFocus]. Runs unguarded — [startFocus] owns
  /// the in-flight bookkeeping around it.
  Future<void> _startFocusTransition(String todoId) async {
    final db = ref.read(databaseProvider);
    final now = DateTime.now();

    // One thing at a time: a Focus on a Habit does not run beside an Outcome.
    // Closing it and opening the Outcome engagement is one transaction, so a
    // Habit start that overlaps this one either commits first (and is closed
    // here) or commits after (and closes this engagement): never both open.
    await db.capturing(() async {
      await db.habitFocusDao.closeHabitFocus(
        userId: ref.read(currentUserIdProvider),
        now: now,
      );

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
    });
    state = FocusModeState(
      activeTodoId: todoId,
      sessionStart: now,
    );
  }

  /// Task id and transition future of the [startFocus] call currently in
  /// flight, or null.
  String? _startingTodoId;
  Future<void>? _startFocusInFlight;

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

  /// Moves Focus straight from the Outcome just completed to [todoId], with
  /// no pass through the list: closes any open TimeLog, opens one on [todoId]
  /// and points the session at it in one write (issue #407).
  ///
  /// The state never reads inactive in between, so the Focus screen is not
  /// sent back to the list. Without an open session the engagement is ad hoc,
  /// as in [startFocus].
  Future<void> advanceTo(String todoId) async {
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
      final previousTodoId = state.activeTodoId;
      if (previousTodoId != null) {
        await db.timeLogDao.closeLog(taskId: previousTodoId);
      }
      await db.timeLogDao.openLog(
        taskId: todoId,
        userId: ref.read(currentUserIdProvider),
        now: now,
      );
    }
    state = FocusModeState(activeTodoId: todoId, sessionStart: now);
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

  /// Clears the in-memory engagement only. The store was already settled by
  /// another writer (a Habit Focus start), so nothing is written here: a later
  /// Outcome engagement that committed in the meantime must not be closed.
  void resetState() {
    state = const FocusModeState();
  }
}

final focusModeProvider =
    NotifierProvider<FocusModeNotifier, FocusModeState>(FocusModeNotifier.new);
