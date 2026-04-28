/// DAO for GTD views: next actions, waiting for, maybe, by-project,
/// by-area, and the general-purpose [transitionState] method.
library;

import 'package:drift/drift.dart';

import '../../models/gtd_state_machine.dart';
import '../../models/todo.dart' show GtdState, Intent;
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

  Stream<List<Todo>> _watchAllForUser(String userId) {
    return (select(todos)
          ..where((t) => t.userId.equals(userId))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .watch();
  }

  /// Returns a stream of [Todo]s with [state] belonging to [userId] whose
  /// tags include ALL of [tagIds] (AND semantics).
  ///
  /// When [excludeIntent] is non-null, rows with that intent value are excluded.
  /// Watches both [todos] and [todoTags] so the stream re-emits when either
  /// table changes.  Uses `todos.map(row.data)` to produce typed [Todo]
  /// objects without repeating the column-mapping logic.
  Stream<List<Todo>> _watchFilteredByStateAndTags(
    String userId,
    String state,
    Set<String> tagIds, {
    String? excludeIntent,
  }) {
    assert(tagIds.isNotEmpty);
    final n = tagIds.length;
    final placeholders = List.filled(n, '?').join(', ');
    final intentClause =
        excludeIntent != null ? ' AND todos.intent != ?' : '';
    final intentVar =
        excludeIntent != null ? [Variable(excludeIntent)] : <Variable>[];
    return customSelect(
      'SELECT todos.* FROM todos '
      'WHERE todos.user_id = ? AND todos.state = ?$intentClause '
      'AND (SELECT COUNT(DISTINCT tag_id) FROM todo_tags '
      '     WHERE todo_id = todos.id AND user_id = ? '
      '       AND tag_id IN ($placeholders)) = $n '
      'ORDER BY todos.created_at',
      variables: [
        Variable(userId),
        Variable(state),
        ...intentVar,
        Variable(userId),
        ...tagIds.map(Variable.new),
      ],
      readsFrom: {todos, todoTags},
    ).watch().map((rows) => rows.map((row) => todos.map(row.data)).toList());
  }

  /// Stream of next-action todos for [userId] (excludes intent = 'maybe').
  ///
  /// When [tagIds] is non-empty only todos carrying **all** specified tags are
  /// returned (AND semantics).
  Stream<List<Todo>> watchNextActions(String userId,
      {Set<String> tagIds = const {}}) {
    if (tagIds.isEmpty) {
      return _watchAllForUser(userId).map(
        (all) => all
            .where((t) =>
                t.state == GtdState.nextAction.value && t.intent != 'maybe')
            .toList(),
      );
    }
    return _watchFilteredByStateAndTags(
        userId, GtdState.nextAction.value, tagIds,
        excludeIntent: 'maybe');
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

  /// Stream of maybe-intent todos for [userId] (intent = 'maybe', state != 'done').
  ///
  /// When [tagIds] is non-empty only todos carrying **all** specified tags are
  /// returned (AND semantics).
  Stream<List<Todo>> watchMaybe(String userId,
      {Set<String> tagIds = const {}}) {
    if (tagIds.isEmpty) {
      return customSelect(
        'SELECT * FROM todos WHERE user_id = ? AND intent = ? AND state != ?'
        ' ORDER BY created_at',
        variables: [Variable(userId), Variable('maybe'), Variable('done')],
        readsFrom: {todos},
      ).watch().map((rows) => rows.map((row) => todos.map(row.data)).toList());
    }
    final n = tagIds.length;
    final placeholders = List.filled(n, '?').join(', ');
    return customSelect(
      'SELECT todos.* FROM todos '
      'WHERE todos.user_id = ? AND todos.intent = ? AND todos.state != ? '
      'AND (SELECT COUNT(DISTINCT tag_id) FROM todo_tags '
      '     WHERE todo_id = todos.id AND user_id = ? '
      '       AND tag_id IN ($placeholders)) = $n '
      'ORDER BY todos.created_at',
      variables: [
        Variable(userId),
        Variable('maybe'),
        Variable('done'),
        Variable(userId),
        ...tagIds.map(Variable.new),
      ],
      readsFrom: {todos, todoTags},
    ).watch().map((rows) => rows.map((row) => todos.map(row.data)).toList());
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

  /// General-purpose state transition with TimeLog side effects.
  ///
  /// - Validates [newState] via [GtdStateMachine].
  /// - When transitioning **to** [GtdState.inProgress]: opens a [TimeLog] row.
  /// - When transitioning **from** [GtdState.inProgress]: closes the open
  ///   [TimeLog] row and recomputes [timeSpentMinutes] from the SUM.
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
      final leavingInProgress = from == GtdState.inProgress;
      final enteringInProgress = newState == GtdState.inProgress;

      if (leavingInProgress) {
        await attachedDatabase.timeLogDao
            .closeLog(taskId: todoId, now: effectiveNow);
      }
      if (enteringInProgress) {
        await attachedDatabase.timeLogDao
            .openLog(taskId: todoId, userId: userId, now: effectiveNow);
      }

      var companion = _buildTransitionCompanion(row, newState, effectiveNow);

      if (leavingInProgress) {
        final total =
            await attachedDatabase.timeLogDao.totalMinutesForTask(todoId);
        companion = companion.copyWith(timeSpentMinutes: Value(total));
      }

      await (update(todos)
            ..where((t) => t.id.equals(todoId) & t.userId.equals(userId)))
          .write(companion);
    });
  }

  TodosCompanion _buildTransitionCompanion(
    Todo row,
    GtdState newState,
    DateTime now,
  ) {
    // inProgressSince is inert after this PR; TimeLog.startedAt is canonical.
    // timeSpentMinutes is conditionally overwritten by transitionState via
    // copyWith when leaving inProgress (recomputed from TimeLog SUM).
    return TodosCompanion(
      state: Value(newState.value),
      inProgressSince: const Value(null),
      updatedAt: Value(now),
      selectedForToday: const Value.absent(),
    );
  }

  // ---------------------------------------------------------------------------
  // Daily planning queries
  // ---------------------------------------------------------------------------

  /// Stream of next-action todos for [userId] not yet reviewed today.
  ///
  /// A task is "not yet reviewed" when its [dailySelectionDate] is null or
  /// does not equal [today] (ISO-8601 date string).
  Stream<List<Todo>> watchNextActionsForPlanning(String userId, String today) {
    return _watchAllForUser(userId).map((all) => all
        .where((t) =>
            t.state == GtdState.nextAction.value &&
            t.intent != 'maybe' &&
            (t.dailySelectionDate == null || t.dailySelectionDate != today))
        .toList());
  }

  /// Stream of next-action todos for [userId] skipped today.
  Stream<List<Todo>> watchSkippedNextActionsForPlanning(String userId, String today) {
    return _watchAllForUser(userId).map((all) => all
        .where((t) =>
            t.state == GtdState.nextAction.value &&
            t.intent != 'maybe' &&
            t.selectedForToday == false &&
            t.dailySelectionDate == today)
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

  // ---------------------------------------------------------------------------
  // Intent mutations (orthogonal to GTD state)
  // ---------------------------------------------------------------------------

  /// Sets the [intent] column for a todo without touching its GTD state.
  ///
  /// [intent] must be one of: next | maybe | trash.
  /// [now] overrides the timestamp used for [updatedAt]; defaults to [DateTime.now()].
  Future<void> setIntent(String todoId, String userId, Intent intent,
      {DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc().toIso8601String();
    await customUpdate(
      'UPDATE todos SET intent = ?, updated_at = ? WHERE id = ? AND user_id = ?',
      variables: [
        Variable(intent.value),
        Variable(ts),
        Variable(todoId),
        Variable(userId),
      ],
      updates: {todos},
      updateKind: UpdateKind.update,
    );
  }

  /// Defers a todo to the "maybe" list by setting intent = 'maybe'.
  ///
  /// Does not alter the GTD state — intent is orthogonal to state.
  Future<void> deferTaskToMaybe(String todoId, String userId, {DateTime? now}) =>
      setIntent(todoId, userId, Intent.maybe, now: now);

  /// Update mutable todo fields (title, notes, energy level, time estimate, due date).
  Future<void> updateFields(
    String todoId,
    String userId, {
    String? title,
    String? notes,
    String? energyLevel,
    int? timeEstimate,
    DateTime? dueDate,
    bool clearDueDate = false,
  }) async {
    final companion = TodosCompanion(
      updatedAt: Value(DateTime.now()),
      title: title != null ? Value(title) : const Value.absent(),
      notes: notes != null ? Value(notes) : const Value.absent(),
      energyLevel: energyLevel != null ? Value(energyLevel) : const Value.absent(),
      timeEstimate: timeEstimate != null ? Value(timeEstimate) : const Value.absent(),
      // Normalise to UTC; see rescheduleTask for rationale.
      dueDate: clearDueDate
          ? const Value(null)
          : dueDate != null
              ? Value(dueDate.toUtc())
              : const Value.absent(),
    );
    await (update(todos)
          ..where((t) => t.id.equals(todoId) & t.userId.equals(userId)))
        .write(companion);
  }
}
