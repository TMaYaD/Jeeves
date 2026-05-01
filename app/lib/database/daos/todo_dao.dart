/// DAO for GTD views: next actions, waiting for, maybe, by-project, by-area.
library;

import 'package:drift/drift.dart';

import '../../models/todo.dart' show Intent;
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

  /// Returns a stream of clarified, non-done [Todo]s for [userId] whose
  /// tags include ALL of [tagIds] (AND semantics).
  ///
  /// When [excludeIntent] is non-null, rows with that intent value are excluded.
  /// Watches both [todos] and [todoTags] so the stream re-emits when either
  /// table changes.
  Stream<List<Todo>> _watchFilteredByTags(
    String userId,
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
      'WHERE todos.user_id = ?$intentClause '
      'AND todos.clarified = 1 '
      'AND todos.done_at IS NULL '
      'AND (SELECT COUNT(DISTINCT tag_id) FROM todo_tags '
      '     WHERE todo_id = todos.id AND user_id = ? '
      '       AND tag_id IN ($placeholders)) = $n '
      'ORDER BY todos.created_at',
      variables: [
        Variable(userId),
        ...intentVar,
        Variable(userId),
        ...tagIds.map(Variable.new),
      ],
      readsFrom: {todos, todoTags},
    ).watch().map((rows) => rows.map((row) => todos.map(row.data)).toList());
  }

  /// Stream of next-action todos for [userId] (excludes intent = 'maybe').
  ///
  /// Only clarified (processed) todos are returned.  When [tagIds] is
  /// non-empty only todos carrying **all** specified tags are returned
  /// (AND semantics).
  Stream<List<Todo>> watchNextActions(String userId,
      {Set<String> tagIds = const {}}) {
    if (tagIds.isEmpty) {
      return _watchAllForUser(userId).map(
        (all) => all
            .where((t) =>
                t.intent != 'maybe' &&
                t.clarified &&
                t.doneAt == null)
            .toList(),
      );
    }
    return _watchFilteredByTags(userId, tagIds, excludeIntent: 'maybe');
  }

  /// Stream of "Waiting For" todos for [userId].
  ///
  /// Returns clarified, non-done, intent='next' todos that have at least one
  /// person-typed tag. When [tagIds] is non-empty only todos carrying **all**
  /// specified (context/filter) tags are returned (AND semantics).
  Stream<List<Todo>> watchPersonTagged(String userId,
      {Set<String> tagIds = const {}}) {
    if (tagIds.isEmpty) {
      return customSelect(
        'SELECT DISTINCT todos.* FROM todos '
        'JOIN todo_tags tt ON tt.todo_id = todos.id '
        'JOIN tags tg ON tg.id = tt.tag_id AND tg.type = ? '
        'WHERE todos.user_id = ? '
        'AND todos.clarified = 1 '
        'AND todos.done_at IS NULL '
        'AND todos.intent = ? '
        'ORDER BY todos.created_at',
        variables: [
          Variable('person'),
          Variable(userId),
          Variable('next'),
        ],
        readsFrom: {todos, todoTags, tags},
      ).watch().map((rows) => rows.map((row) => todos.map(row.data)).toList());
    }
    return _watchPersonTaggedFilteredByTags(userId, tagIds);
  }

  /// Tag-filtered variant of [watchPersonTagged].
  Stream<List<Todo>> _watchPersonTaggedFilteredByTags(
      String userId, Set<String> tagIds) {
    assert(tagIds.isNotEmpty);
    final n = tagIds.length;
    final placeholders = List.filled(n, '?').join(', ');
    return customSelect(
      'SELECT DISTINCT todos.* FROM todos '
      'JOIN todo_tags tt ON tt.todo_id = todos.id '
      'JOIN tags tg ON tg.id = tt.tag_id AND tg.type = ? '
      'WHERE todos.user_id = ? '
      'AND todos.clarified = 1 '
      'AND todos.done_at IS NULL '
      'AND todos.intent = ? '
      'AND (SELECT COUNT(DISTINCT tag_id) FROM todo_tags '
      '     WHERE todo_id = todos.id AND user_id = ? '
      '       AND tag_id IN ($placeholders)) = $n '
      'ORDER BY todos.created_at',
      variables: [
        Variable('person'),
        Variable(userId),
        Variable('next'),
        Variable(userId),
        ...tagIds.map(Variable.new),
      ],
      readsFrom: {todos, todoTags, tags},
    ).watch().map((rows) => rows.map((row) => todos.map(row.data)).toList());
  }

  /// Stream of todos grouped by person-tag.
  ///
  /// Each todo appears once per person-tag it carries.  A todo with two
  /// person-tags appears in two entries.  Results are ordered by tag name
  /// then todo creation date — insertion order matches the grouped view.
  Stream<Map<Tag, List<Todo>>> watchPersonTaggedGrouped(String userId) {
    return customSelect(
      'SELECT '
      '  todos.id, todos.title, todos.notes, todos.priority, '
      '  todos.due_date, todos.created_at, todos.updated_at, '
      '  todos.done_at, todos.clarified, todos.intent, '
      '  todos.time_estimate, todos.energy_level, todos.capture_source, '
      '  todos.location_id, todos.user_id, '
      '  todos.last_clarified_at, todos.time_spent_minutes, '
      '  tg.id AS ptag_id, tg.name AS ptag_name, '
      '  tg.color AS ptag_color, tg.user_id AS ptag_user_id '
      'FROM todos '
      'JOIN todo_tags tt ON tt.todo_id = todos.id '
      'JOIN tags tg ON tg.id = tt.tag_id AND tg.type = ? '
      'WHERE todos.user_id = ? '
      '  AND todos.clarified = 1 '
      '  AND todos.done_at IS NULL '
      '  AND todos.intent = ? '
      'ORDER BY tg.name, todos.created_at',
      variables: [
        Variable('person'),
        Variable(userId),
        Variable('next'),
      ],
      readsFrom: {todos, todoTags, tags},
    ).watch().map((rows) {
      final result = <Tag, List<Todo>>{};
      for (final row in rows) {
        final tag = Tag(
          id: row.read<String>('ptag_id'),
          name: row.read<String>('ptag_name'),
          color: row.readNullable<String>('ptag_color'),
          type: 'person',
          userId: row.read<String>('ptag_user_id'),
        );
        result.putIfAbsent(tag, () => []).add(todos.map(row.data));
      }
      return result;
    });
  }

  /// Stream of maybe-intent todos for [userId] (intent = 'maybe', done_at IS NULL).
  ///
  /// Only clarified (processed) todos are returned.  When [tagIds] is
  /// non-empty only todos carrying **all** specified tags are returned
  /// (AND semantics).
  Stream<List<Todo>> watchMaybe(String userId,
      {Set<String> tagIds = const {}}) {
    if (tagIds.isEmpty) {
      return customSelect(
        'SELECT * FROM todos WHERE user_id = ? AND intent = ? AND done_at IS NULL'
        ' AND clarified = 1 ORDER BY created_at',
        variables: [Variable(userId), Variable('maybe')],
        readsFrom: {todos},
      ).watch().map((rows) => rows.map((row) => todos.map(row.data)).toList());
    }
    final n = tagIds.length;
    final placeholders = List.filled(n, '?').join(', ');
    return customSelect(
      'SELECT todos.* FROM todos '
      'WHERE todos.user_id = ? AND todos.intent = ? AND todos.done_at IS NULL '
      'AND todos.clarified = 1 '
      'AND (SELECT COUNT(DISTINCT tag_id) FROM todo_tags '
      '     WHERE todo_id = todos.id AND user_id = ? '
      '       AND tag_id IN ($placeholders)) = $n '
      'ORDER BY todos.created_at',
      variables: [
        Variable(userId),
        Variable('maybe'),
        Variable(userId),
        ...tagIds.map(Variable.new),
      ],
      readsFrom: {todos, todoTags},
    ).watch().map((rows) => rows.map((row) => todos.map(row.data)).toList());
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
  // Done
  // ---------------------------------------------------------------------------

  /// Marks [todoId] as done by setting [done_at] to the current UTC timestamp.
  ///
  /// [now] is injectable for deterministic testing; defaults to [DateTime.now].
  Future<void> markDone(String todoId, String userId, {DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc().toIso8601String();
    await customUpdate(
      'UPDATE todos SET done_at = ?, updated_at = ?, clarified = 1 '
      'WHERE id = ? AND user_id = ?',
      variables: [Variable(ts), Variable(ts), Variable(todoId), Variable(userId)],
      updates: {todos},
      updateKind: UpdateKind.update,
    );
  }

  /// Stream of completed todos for [userId], ordered by [done_at] descending.
  Stream<List<Todo>> watchDone(String userId) {
    return customSelect(
      'SELECT * FROM todos WHERE user_id = ? AND done_at IS NOT NULL '
      'ORDER BY done_at DESC',
      variables: [Variable(userId)],
      readsFrom: {todos},
    ).watch().map((rows) => rows.map((r) => todos.map(r.data)).toList());
  }

  // ---------------------------------------------------------------------------
  // Bulk id lookup
  // ---------------------------------------------------------------------------

  /// Stream of [Todo] rows whose [id] is in [ids], ordered by creation date.
  ///
  /// Returns an empty stream when [ids] is empty.
  Stream<List<Todo>> watchTodosById(String userId, List<String> ids) {
    if (ids.isEmpty) return Stream.value([]);
    final placeholders = ids.map((_) => '?').join(', ');
    return customSelect(
      'SELECT * FROM todos WHERE user_id = ? AND id IN ($placeholders) '
      'ORDER BY created_at',
      variables: [Variable(userId), ...ids.map(Variable.new)],
      readsFrom: {todos},
    ).watch().map((rows) => rows.map((r) => todos.map(r.data)).toList());
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

  /// Stamps [last_clarified_at] to now for [todoId] owned by [userId].
  ///
  /// Called whenever a person-typed TodoTag is added to or removed from the todo.
  /// [now] overrides the timestamp for deterministic testing.
  Future<void> stampLastClarifiedAt(String todoId, String userId,
      {DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc();
    await (update(todos)
          ..where((t) => t.id.equals(todoId) & t.userId.equals(userId)))
        .write(TodosCompanion(
      lastClarifiedAt: Value(ts),
      updatedAt: Value(ts),
    ));
  }

  /// Restores a done or trashed todo to active next-action status.
  Future<void> restore(String todoId, String userId) async {
    final ts = DateTime.now().toUtc().toIso8601String();
    await customUpdate(
      'UPDATE todos SET done_at = NULL, intent = ?, updated_at = ? '
      'WHERE id = ? AND user_id = ?',
      variables: [
        Variable('next'),
        Variable(ts),
        Variable(todoId),
        Variable(userId),
      ],
      updates: {todos},
      updateKind: UpdateKind.update,
    );
  }

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
