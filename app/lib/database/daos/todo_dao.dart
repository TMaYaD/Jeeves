/// DAO for GTD views: next actions, waiting for, someday/maybe, by-project,
/// by-area, and the general-purpose [transitionState] method.
library;

import 'package:drift/drift.dart';

import '../../models/gtd_state_machine.dart';
import '../../models/todo.dart' show GtdState;
import '../gtd_database.dart';

part 'todo_dao.g.dart';

@DriftAccessor(tables: [Todos, Tags, TodoTags])
class TodoDao extends DatabaseAccessor<GtdDatabase> with _$TodoDaoMixin {
  TodoDao(super.db);

  // ---------------------------------------------------------------------------
  // Single-todo helpers
  // ---------------------------------------------------------------------------

  /// Returns a single todo by [todoId] scoped to [userId], or null if not found.
  Future<Todo?> getTodo(String todoId, String userId) {
    return (select(todos)
          ..where((t) => t.id.equals(todoId) & t.userId.equals(userId)))
        .getSingleOrNull();
  }

  /// Stream that re-emits a single todo (scoped to [userId]) whenever it changes.
  Stream<Todo?> watchTodo(String todoId, String userId) {
    return (select(todos)
          ..where((t) => t.id.equals(todoId) & t.userId.equals(userId)))
        .watchSingleOrNull();
  }

  // ---------------------------------------------------------------------------
  // GTD list watchers
  // ---------------------------------------------------------------------------

  /// Stream of all [userId] todos, watched for reactive blocked-by filtering.
  Stream<List<Todo>> _watchAllForUser(String userId) {
    return (select(todos)
          ..where((t) => t.userId.equals(userId))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .watch();
  }

  /// Returns items from [allItems] that are unblocked in [byId].
  ///
  /// A todo is unblocked when [Todo.blockedByTodoId] is null OR the blocking
  /// todo no longer exists or is in the 'done' state.
  List<Todo> _filterUnblocked(List<Todo> items, Map<String, Todo> byId) {
    return items.where((t) {
      if (t.blockedByTodoId == null) return true;
      final blocker = byId[t.blockedByTodoId];
      return blocker == null || blocker.state == GtdState.done.value;
    }).toList();
  }

  /// Returns a stream of [Todo]s with [state] belonging to [userId] whose
  /// tags include ALL of [tagIds] (AND semantics).
  ///
  /// Watches both [todos] and [todoTags] so the stream re-emits when either
  /// table changes.  Uses `todos.map(row.data)` to produce typed [Todo]
  /// objects without repeating the column-mapping logic.
  Stream<List<Todo>> _watchFilteredByStateAndTags(
    String userId,
    String state,
    Set<String> tagIds,
  ) {
    assert(tagIds.isNotEmpty);
    final n = tagIds.length;
    final placeholders = List.filled(n, '?').join(', ');
    return customSelect(
      'SELECT todos.* FROM todos '
      'WHERE todos.user_id = ? AND todos.state = ? '
      'AND (SELECT COUNT(DISTINCT tag_id) FROM todo_tags '
      '     WHERE todo_id = todos.id AND user_id = ? '
      '       AND tag_id IN ($placeholders)) = $n '
      'ORDER BY todos.created_at',
      variables: [
        Variable(userId),
        Variable(state),
        Variable(userId),
        ...tagIds.map(Variable.new),
      ],
      readsFrom: {todos, todoTags},
    ).watch().map((rows) => rows.map((row) => todos.map(row.data)).toList());
  }

  /// Stream of next-action todos for [userId], excluding blocked tasks.
  ///
  /// When [tagIds] is non-empty only todos carrying **all** specified tags are
  /// returned (AND semantics).
  Stream<List<Todo>> watchNextActions(String userId,
      {Set<String> tagIds = const {}}) {
    if (tagIds.isEmpty) {
      return _watchAllForUser(userId).map((all) {
        final byId = {for (final t in all) t.id: t};
        final nextActions =
            all.where((t) => t.state == GtdState.nextAction.value).toList();
        return _filterUnblocked(nextActions, byId);
      });
    }

    // Tag-filtered: use SQL-level AND filter, then apply blocked-by in memory.
    return _watchFilteredByStateAndTags(
            userId, GtdState.nextAction.value, tagIds)
        .asyncMap((filteredNextActions) async {
      final allTodos =
          await (select(todos)..where((t) => t.userId.equals(userId))).get();
      final byId = {for (final t in allTodos) t.id: t};
      return _filterUnblocked(filteredNextActions, byId);
    });
  }

  /// Stream of waiting-for todos for [userId].
  ///
  /// When [tagIds] is non-empty only todos carrying **all** specified tags are
  /// returned (AND semantics).
  Stream<List<Todo>> watchWaitingFor(String userId,
      {Set<String> tagIds = const {}}) {
    if (tagIds.isEmpty) {
      return _watchAllForUser(userId).map(
        (all) =>
            all.where((t) => t.state == GtdState.waitingFor.value).toList(),
      );
    }
    return _watchFilteredByStateAndTags(
        userId, GtdState.waitingFor.value, tagIds);
  }

  /// Stream of someday/maybe todos for [userId].
  ///
  /// When [tagIds] is non-empty only todos carrying **all** specified tags are
  /// returned (AND semantics).
  Stream<List<Todo>> watchSomedayMaybe(String userId,
      {Set<String> tagIds = const {}}) {
    if (tagIds.isEmpty) {
      return _watchAllForUser(userId).map(
        (all) =>
            all.where((t) => t.state == GtdState.somedayMaybe.value).toList(),
      );
    }
    return _watchFilteredByStateAndTags(
        userId, GtdState.somedayMaybe.value, tagIds);
  }

  /// Stream of todos matching an arbitrary [state] string for [userId].
  ///
  /// When [tagIds] is non-empty only todos carrying **all** specified tags are
  /// returned (AND semantics).
  Stream<List<Todo>> watchByState(String userId, String state,
      {Set<String> tagIds = const {}}) {
    if (tagIds.isEmpty) {
      return (select(todos)
            ..where((t) => t.userId.equals(userId) & t.state.equals(state))
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .watch();
    }
    return _watchFilteredByStateAndTags(userId, state, tagIds);
  }

  /// Stream of todos matching either next_action or blocked state for [userId].
  Stream<List<Todo>> watchNextActionsAndBlocked(String userId) {
    return (select(todos)
          ..where((t) =>
              t.userId.equals(userId) &
              (t.state.equals(GtdState.nextAction.value) |
                  t.state.equals(GtdState.blocked.value)))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .watch();
  }

  /// Stream of todos associated with a specific project tag [projectTagId].
  Stream<List<Todo>> watchByProject(String userId, String projectTagId) {
    final query = select(todos).join([
      innerJoin(todoTags, todoTags.todoId.equalsExp(todos.id)),
    ])
      ..where(todos.userId.equals(userId) & todoTags.tagId.equals(projectTagId));
    return query.map((row) => row.readTable(todos)).watch();
  }

  /// Stream of todos associated with a specific area tag [areaTagId].
  Stream<List<Todo>> watchByArea(String userId, String areaTagId) {
    final query = select(todos).join([
      innerJoin(todoTags, todoTags.todoId.equalsExp(todos.id)),
    ])
      ..where(todos.userId.equals(userId) & todoTags.tagId.equals(areaTagId));
    return query.map((row) => row.readTable(todos)).watch();
  }

  // ---------------------------------------------------------------------------
  // State transitions
  // ---------------------------------------------------------------------------

  /// General-purpose state transition with time-logging side effects.
  ///
  /// - Validates [newState] via [GtdStateMachine].
  /// - When transitioning **to** [GtdState.inProgress]: sets [inProgressSince].
  /// - When transitioning **from** [GtdState.inProgress]: computes elapsed
  ///   minutes (rounded up) since [inProgressSince] and accumulates into
  ///   [timeSpentMinutes]; clears [inProgressSince].
  ///
  /// [now] is injectable for deterministic testing; defaults to [DateTime.now].
  Future<void> transitionState(
    String todoId,
    String userId,
    GtdState newState, {
    DateTime? now,
  }) async {
    await transaction(() async {
      final row = await (select(todos)
            ..where((t) => t.id.equals(todoId) & t.userId.equals(userId)))
          .getSingleOrNull();
      if (row == null) return;

      final from = GtdState.fromString(row.state);
      GtdStateMachine.validate(from, newState);

      if (newState == GtdState.inProgress) {
        final existing = await (select(todos)
              ..where((t) =>
                  t.userId.equals(userId) &
                  t.state.equals(GtdState.inProgress.value) &
                  t.id.isNotValue(todoId)))
            .getSingleOrNull();
        if (existing != null) {
          throw StateError(
            'Cannot transition to inProgress: task ${existing.id} is already inProgress.',
          );
        }
      }

      final effectiveNow = now ?? DateTime.now();
      final companion = _buildTransitionCompanion(row, newState, effectiveNow);

      await (update(todos)
            ..where((t) => t.id.equals(todoId) & t.userId.equals(userId)))
          .write(companion);

      if (newState == GtdState.done) {
        // Unblock any tasks that were blocked by this one
        final dependents = await (select(todos)
              ..where((t) => t.blockedByTodoId.equals(todoId) & t.userId.equals(userId)))
            .get();
        for (final dep in dependents) {
          if (dep.state == GtdState.blocked.value) {
            await (update(todos)..where((t) => t.id.equals(dep.id)))
                .write(TodosCompanion(
              state: Value(GtdState.nextAction.value),
              updatedAt: Value(effectiveNow),
            ));
          }
        }
      }
    });
  }

  TodosCompanion _buildTransitionCompanion(
    Todo row,
    GtdState newState,
    DateTime now,
  ) {
    var timeSpent = row.timeSpentMinutes;
    String? newInProgressSince = row.inProgressSince;

    if (GtdState.fromString(row.state) == GtdState.inProgress &&
        row.inProgressSince != null) {
      // Leaving inProgress — log elapsed time (rounded up to nearest minute).
      final started = DateTime.tryParse(row.inProgressSince!);
      if (started != null) {
        final elapsed = now.difference(started);
        final minutes = (elapsed.inSeconds / 60).ceil();
        timeSpent += minutes.clamp(0, double.maxFinite.toInt());
      }
      newInProgressSince = null;
    }

    if (newState == GtdState.inProgress) {
      newInProgressSince = now.toIso8601String();
    }

    return TodosCompanion(
      state: Value(newState.value),
      timeSpentMinutes: Value(timeSpent),
      inProgressSince: Value(newInProgressSince),
      updatedAt: Value(now),
      // Transitioning to deferred removes the task from today's focus list.
      selectedForToday: newState == GtdState.deferred
          ? const Value(false)
          : const Value.absent(),
    );
  }

  // ---------------------------------------------------------------------------
  // Daily planning queries
  // ---------------------------------------------------------------------------

  /// Formats a [DateTime] as an ISO-8601 date string (yyyy-MM-dd).
  static String _fmtDate(DateTime dt) =>
      '${dt.year.toString().padLeft(4, '0')}-'
      '${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')}';

  /// Stream of next-action todos for [userId] not yet reviewed today.
  ///
  /// A task is "not yet reviewed" when its [dailySelectionDate] is null or
  /// does not equal [today] (ISO-8601 date string). Blocked tasks are excluded
  /// to match the standard next-actions view.
  Stream<List<Todo>> watchNextActionsForPlanning(String userId, String today) {
    return _watchAllForUser(userId).map((all) {
      final byId = {for (final t in all) t.id: t};
      final pending = all
          .where((t) =>
              t.state == GtdState.nextAction.value &&
              (t.dailySelectionDate == null || t.dailySelectionDate != today))
          .toList();
      return _filterUnblocked(pending, byId);
    });
  }

  /// Stream of next-action todos for [userId] skipped today.
  Stream<List<Todo>> watchSkippedNextActionsForPlanning(String userId, String today) {
    return _watchAllForUser(userId).map((all) {
      final byId = {for (final t in all) t.id: t};
      final skipped = all
          .where((t) =>
              t.state == GtdState.nextAction.value &&
              t.selectedForToday == false &&
              t.dailySelectionDate == today)
          .toList();
      return _filterUnblocked(skipped, byId);
    });
  }

  /// Stream of scheduled todos with a due date on [today] that have not yet
  /// been confirmed (i.e. [dailySelectionDate] is null or != [today]).
  Stream<List<Todo>> watchScheduledDueToday(String userId, String today) {
    return _watchAllForUser(userId).map((all) => all
        .where((t) =>
            t.state == GtdState.scheduled.value &&
            t.dueDate != null &&
            // Storage is UTC (see TodoDao.rescheduleTask / updateFields) but
            // [today] is a *local* calendar day from planningToday().  Convert
            // back before formatting so the comparison is local-day vs
            // local-day; otherwise non-UTC devices drop tasks a day early.
            _fmtDate(t.dueDate!.toLocal()) == today &&
            (t.dailySelectionDate == null || t.dailySelectionDate != today))
        .toList());
  }

  /// Stream of todos selected for [today] (selectedForToday == true and
  /// dailySelectionDate == [today]).
  Stream<List<Todo>> watchSelectedForToday(String userId, String today) {
    return _watchAllForUser(userId).map((all) => all
        .where((t) =>
            t.selectedForToday == true && t.dailySelectionDate == today)
        .toList());
  }

  /// Stream of todos selected for [today] that are missing a time estimate.
  Stream<List<Todo>> watchSelectedTasksMissingEstimates(
      String userId, String today) {
    return watchSelectedForToday(userId, today)
        .map((selected) => selected.where((t) => t.timeEstimate == null).toList());
  }

  /// Marks [id] as selected for [today].
  ///
  /// [now] overrides the timestamp used for [updatedAt]; defaults to
  /// [DateTime.now()]. Pass an explicit value in tests for determinism.
  Future<void> selectForToday(String id, String userId, String date,
      {DateTime? now}) async {
    final ts = now ?? DateTime.now();
    await (update(todos)
          ..where((t) => t.id.equals(id) & t.userId.equals(userId)))
        .write(TodosCompanion(
      selectedForToday: const Value(true),
      dailySelectionDate: Value(date),
      updatedAt: Value(ts),
    ));
  }

  /// Marks [id] as skipped for [today].
  ///
  /// [now] overrides the timestamp used for [updatedAt]; defaults to
  /// [DateTime.now()]. Pass an explicit value in tests for determinism.
  Future<void> skipForToday(String id, String userId, String date,
      {DateTime? now}) async {
    final ts = now ?? DateTime.now();
    await (update(todos)
          ..where((t) => t.id.equals(id) & t.userId.equals(userId)))
        .write(TodosCompanion(
      selectedForToday: const Value(false),
      dailySelectionDate: Value(date),
      updatedAt: Value(ts),
    ));
  }

  /// Undoes a review decision — resets [selectedForToday] and
  /// [dailySelectionDate] so the task reappears in the planning list.
  ///
  /// [now] overrides the timestamp used for [updatedAt]; defaults to
  /// [DateTime.now()]. Pass an explicit value in tests for determinism.
  Future<void> undoReview(String id, String userId, {DateTime? now}) async {
    final ts = now ?? DateTime.now();
    await (update(todos)
          ..where((t) => t.id.equals(id) & t.userId.equals(userId)))
        .write(TodosCompanion(
      selectedForToday: Value(null),
      dailySelectionDate: Value(null),
      updatedAt: Value(ts),
    ));
  }

  /// Defers [id] to Someday/Maybe via the GTD state machine.
  Future<void> deferTaskToSomeday(String id, String userId) async {
    await transitionState(id, userId, GtdState.somedayMaybe);
  }

  /// Updates the due date for a scheduled task (reschedule without state change).
  ///
  /// [now] overrides the timestamp used for [updatedAt]; defaults to
  /// [DateTime.now()]. Pass an explicit value in tests for determinism.
  Future<void> rescheduleTask(
      String id, String userId, DateTime newDueDate, {DateTime? now}) async {
    final ts = now ?? DateTime.now();
    await (update(todos)
          ..where((t) => t.id.equals(id) & t.userId.equals(userId)))
        .write(TodosCompanion(
      // Store UTC so Drift's storeDateTimeAsText path emits a standard
      // ISO-8601 string (no leading-space offset).  Otherwise PowerSync
      // uploads "...000 +05:30" which asyncpg's TIMESTAMPTZ encoder
      // rejects, poisoning the CRUD queue.
      dueDate: Value(newDueDate.toUtc()),
      updatedAt: Value(ts),
    ));
  }

  /// Resets planning selections for all todos reviewed on [date].
  ///
  /// Used when re-entering the planning ritual mid-day so the user can
  /// re-evaluate each task from scratch.
  ///
  /// [now] overrides the timestamp used for [updatedAt]; defaults to
  /// [DateTime.now()]. Pass an explicit value in tests for determinism.
  Future<void> clearTodaySelections(String userId, String date,
      {DateTime? now}) async {
    final ts = now ?? DateTime.now();
    await (update(todos)
          ..where(
              (t) => t.userId.equals(userId) & t.dailySelectionDate.equals(date)))
        .write(TodosCompanion(
      selectedForToday: Value(null),
      dailySelectionDate: Value(null),
      updatedAt: Value(ts),
    ));
  }

  /// Resets planning selections only for todos that were **skipped** on [date].
  ///
  /// Used when re-entering the planning ritual so that already-selected tasks
  /// remain in the day's plan while skipped tasks are returned to the
  /// pending-review queue.
  ///
  /// [now] overrides the timestamp used for [updatedAt]; defaults to
  /// [DateTime.now()]. Pass an explicit value in tests for determinism.
  Future<void> clearTodaySkippedSelections(String userId, String date,
      {DateTime? now}) async {
    final ts = now ?? DateTime.now();
    await (update(todos)
          ..where((t) =>
              t.userId.equals(userId) &
              t.dailySelectionDate.equals(date) &
              t.selectedForToday.equals(false)))
        .write(TodosCompanion(
      selectedForToday: Value(null),
      dailySelectionDate: Value(null),
      updatedAt: Value(ts),
    ));
  }

  /// Update mutable todo fields (title, notes, energy level, time estimate).
  Future<void> updateFields(
    String todoId,
    String userId, {
    String? title,
    String? notes,
    String? energyLevel,
    int? timeEstimate,
    String? blockedByTodoId,
    bool clearBlockedBy = false,
    DateTime? dueDate,
    bool clearDueDate = false,
  }) async {
    if (!clearBlockedBy && blockedByTodoId != null) {
      if (blockedByTodoId == todoId) {
        throw ArgumentError.value(
          blockedByTodoId,
          'blockedByTodoId',
          'A todo cannot block itself',
        );
      }
      final blocker = await (select(todos)
            ..where(
                (t) => t.id.equals(blockedByTodoId) & t.userId.equals(userId)))
          .getSingleOrNull();
      if (blocker == null) {
        throw ArgumentError.value(
          blockedByTodoId,
          'blockedByTodoId',
          'Blocking todo was not found for this user',
        );
      }
    }

    final newState = clearBlockedBy
        ? GtdState.nextAction.value
        : (blockedByTodoId != null ? GtdState.blocked.value : null);

    final companion = TodosCompanion(
      updatedAt: Value(DateTime.now()),
      title: title != null ? Value(title) : const Value.absent(),
      notes: notes != null ? Value(notes) : const Value.absent(),
      energyLevel: energyLevel != null ? Value(energyLevel) : const Value.absent(),
      timeEstimate: timeEstimate != null ? Value(timeEstimate) : const Value.absent(),
      state: newState != null ? Value(newState) : const Value.absent(),
      // Normalise to UTC; see rescheduleTask for rationale.
      dueDate: clearDueDate
          ? const Value(null)
          : dueDate != null
              ? Value(dueDate.toUtc())
              : const Value.absent(),
      blockedByTodoId: clearBlockedBy
          ? const Value(null)
          : blockedByTodoId != null
              ? Value(blockedByTodoId)
              : const Value.absent(),
    );
    await (update(todos)
          ..where((t) => t.id.equals(todoId) & t.userId.equals(userId)))
        .write(companion);
  }
}
