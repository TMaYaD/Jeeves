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

  /// Returns a single todo by [todoId], or null if not found.
  Future<Todo?> getTodo(String todoId) {
    return (select(todos)..where((t) => t.id.equals(todoId))).getSingleOrNull();
  }

  /// Stream that re-emits a single todo whenever it changes.
  Stream<Todo?> watchTodo(String todoId) {
    return (select(todos)..where((t) => t.id.equals(todoId)))
        .watchSingleOrNull();
  }

  // ---------------------------------------------------------------------------
  // GTD list watchers
  // ---------------------------------------------------------------------------

  Stream<List<Todo>> _watchAll() {
    return (select(todos)
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .watch();
  }

  /// Returns a stream of clarified, non-done [Todo]s whose tags include ALL of
  /// [tagIds] (AND semantics).
  ///
  /// When [excludeIntent] is non-null, rows with that intent value are excluded.
  /// Watches both [todos] and [todoTags] so the stream re-emits when either
  /// table changes.
  Stream<List<Todo>> _watchFilteredByTags(
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
      'WHERE todos.clarified = 1 '
      'AND todos.done_at IS NULL '
      'AND (SELECT COUNT(DISTINCT tag_id) FROM todo_tags '
      '     WHERE todo_id = todos.id '
      '       AND tag_id IN ($placeholders)) = $n$intentClause '
      'ORDER BY todos.created_at',
      variables: [
        ...tagIds.map(Variable.new),
        ...intentVar,
      ],
      readsFrom: {todos, todoTags},
    ).watch().map((rows) => rows.map((row) => todos.map(row.data)).toList());
  }

  /// Stream of next-action todos (excludes intent = 'maybe').
  ///
  /// Only clarified (processed) todos are returned.  When [tagIds] is
  /// non-empty only todos carrying **all** specified tags are returned
  /// (AND semantics).
  Stream<List<Todo>> watchNextActions({Set<String> tagIds = const {}}) {
    if (tagIds.isEmpty) {
      return _watchAll().map(
        (all) => all
            .where((t) =>
                t.intent != 'maybe' &&
                t.clarified &&
                t.doneAt == null)
            .toList(),
      );
    }
    return _watchFilteredByTags(tagIds, excludeIntent: 'maybe');
  }

  /// Stream of "Waiting For" todos.
  ///
  /// Returns clarified, non-done, intent='next' todos that have at least one
  /// person-typed tag. When [tagIds] is non-empty only todos carrying **all**
  /// specified (context/filter) tags are returned (AND semantics).
  Stream<List<Todo>> watchPersonTagged({Set<String> tagIds = const {}}) {
    if (tagIds.isEmpty) {
      return customSelect(
        'SELECT DISTINCT todos.* FROM todos '
        'JOIN todo_tags tt ON tt.todo_id = todos.id '
        'JOIN tags tg ON tg.id = tt.tag_id AND tg.type = ? '
        'WHERE todos.clarified = 1 '
        'AND todos.done_at IS NULL '
        'AND todos.intent = ? '
        'ORDER BY todos.created_at',
        variables: [
          Variable('person'),
          Variable('next'),
        ],
        readsFrom: {todos, todoTags, tags},
      ).watch().map((rows) => rows.map((row) => todos.map(row.data)).toList());
    }
    return _watchPersonTaggedFilteredByTags(tagIds);
  }

  /// Tag-filtered variant of [watchPersonTagged].
  Stream<List<Todo>> _watchPersonTaggedFilteredByTags(Set<String> tagIds) {
    assert(tagIds.isNotEmpty);
    final n = tagIds.length;
    final placeholders = List.filled(n, '?').join(', ');
    return customSelect(
      'SELECT DISTINCT todos.* FROM todos '
      'JOIN todo_tags tt ON tt.todo_id = todos.id '
      'JOIN tags tg ON tg.id = tt.tag_id AND tg.type = ? '
      'WHERE todos.clarified = 1 '
      'AND todos.done_at IS NULL '
      'AND todos.intent = ? '
      'AND (SELECT COUNT(DISTINCT tag_id) FROM todo_tags '
      '     WHERE todo_id = todos.id '
      '       AND tag_id IN ($placeholders)) = $n '
      'ORDER BY todos.created_at',
      variables: [
        Variable('person'),
        Variable('next'),
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
  Stream<Map<Tag, List<Todo>>> watchPersonTaggedGrouped() {
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
      'WHERE todos.clarified = 1 '
      '  AND todos.done_at IS NULL '
      '  AND todos.intent = ? '
      'ORDER BY tg.name, todos.created_at',
      variables: [
        Variable('person'),
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

  /// Stream of maybe-intent todos (intent = 'maybe', done_at IS NULL).
  ///
  /// Only clarified (processed) todos are returned.  When [tagIds] is
  /// non-empty only todos carrying **all** specified tags are returned
  /// (AND semantics).
  Stream<List<Todo>> watchMaybe({Set<String> tagIds = const {}}) {
    if (tagIds.isEmpty) {
      return customSelect(
        'SELECT * FROM todos WHERE intent = ? AND done_at IS NULL'
        ' AND clarified = 1 ORDER BY created_at',
        variables: [Variable('maybe')],
        readsFrom: {todos},
      ).watch().map((rows) => rows.map((row) => todos.map(row.data)).toList());
    }
    final n = tagIds.length;
    final placeholders = List.filled(n, '?').join(', ');
    return customSelect(
      'SELECT todos.* FROM todos '
      'WHERE todos.intent = ? AND todos.done_at IS NULL '
      'AND todos.clarified = 1 '
      'AND (SELECT COUNT(DISTINCT tag_id) FROM todo_tags '
      '     WHERE todo_id = todos.id '
      '       AND tag_id IN ($placeholders)) = $n '
      'ORDER BY todos.created_at',
      variables: [
        Variable('maybe'),
        ...tagIds.map(Variable.new),
      ],
      readsFrom: {todos, todoTags},
    ).watch().map((rows) => rows.map((row) => todos.map(row.data)).toList());
  }

  /// Stream of todos associated with a specific project tag [projectTagId].
  ///
  /// Returns all todos for the project (including done and inbox items) so the
  /// project detail view can show full history.
  Stream<List<Todo>> watchByProject(String projectTagId) {
    final query = select(todos).join([
      innerJoin(todoTags, todoTags.todoId.equalsExp(todos.id)),
    ])
      ..where(todoTags.tagId.equals(projectTagId))
      ..orderBy([OrderingTerm.asc(todos.createdAt)]);
    return query.map((row) => row.readTable(todos)).watch();
  }

  /// Stream of todos associated with a specific area tag [areaTagId].
  ///
  /// Returns all todos for the area (including done and inbox items) so the
  /// area detail view can show full history.
  Stream<List<Todo>> watchByArea(String areaTagId) {
    final query = select(todos).join([
      innerJoin(todoTags, todoTags.todoId.equalsExp(todos.id)),
    ])
      ..where(todoTags.tagId.equals(areaTagId))
      ..orderBy([OrderingTerm.asc(todos.createdAt)]);
    return query.map((row) => row.readTable(todos)).watch();
  }

  // ---------------------------------------------------------------------------
  // Done
  // ---------------------------------------------------------------------------

  /// Marks [todoId] as done by setting [done_at] to the current UTC timestamp.
  ///
  /// [now] is injectable for deterministic testing; defaults to [DateTime.now].
  Future<void> markDone(String todoId, {DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc().toIso8601String();
    await customUpdate(
      'UPDATE todos SET done_at = ?, updated_at = ?, clarified = 1 '
      'WHERE id = ?',
      variables: [Variable(ts), Variable(ts), Variable(todoId)],
      updates: {todos},
      updateKind: UpdateKind.update,
    );
  }

  /// Stream of completed todos, ordered by [done_at] descending.
  Stream<List<Todo>> watchDone() {
    return customSelect(
      'SELECT * FROM todos WHERE done_at IS NOT NULL '
      'ORDER BY done_at DESC',
      variables: [],
      readsFrom: {todos},
    ).watch().map((rows) => rows.map((r) => todos.map(r.data)).toList());
  }

  // ---------------------------------------------------------------------------
  // Bulk id lookup
  // ---------------------------------------------------------------------------

  /// Stream of [Todo] rows whose [id] is in [ids], ordered by creation date.
  ///
  /// Returns an empty stream when [ids] is empty.
  Stream<List<Todo>> watchTodosById(List<String> ids) {
    if (ids.isEmpty) return Stream.value([]);
    final placeholders = ids.map((_) => '?').join(', ');
    return customSelect(
      'SELECT * FROM todos WHERE id IN ($placeholders) '
      'ORDER BY created_at',
      variables: [...ids.map(Variable.new)],
      readsFrom: {todos},
    ).watch().map((rows) => rows.map((r) => todos.map(r.data)).toList());
  }

  /// Updates the due date for a scheduled task (reschedule without state change).
  ///
  /// [now] overrides the timestamp used for [updatedAt]; defaults to
  /// [DateTime.now()]. Pass an explicit value in tests for determinism.
  Future<void> rescheduleTask(String id, DateTime newDueDate,
      {DateTime? now}) async {
    final ts = now ?? DateTime.now();
    await (update(todos)..where((t) => t.id.equals(id))).write(TodosCompanion(
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
  Future<void> setIntent(String todoId, Intent intent, {DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc().toIso8601String();
    await customUpdate(
      'UPDATE todos SET intent = ?, updated_at = ? WHERE id = ?',
      variables: [
        Variable(intent.value),
        Variable(ts),
        Variable(todoId),
      ],
      updates: {todos},
      updateKind: UpdateKind.update,
    );
  }

  /// Defers a todo to the "maybe" list by setting intent = 'maybe'.
  ///
  /// Does not alter the GTD state — intent is orthogonal to state.
  Future<void> deferTaskToMaybe(String todoId, {DateTime? now}) =>
      setIntent(todoId, Intent.maybe, now: now);

  /// Stamps [last_clarified_at] to now for [todoId].
  ///
  /// Called whenever a person-typed TodoTag is added to or removed from the todo.
  /// [now] overrides the timestamp for deterministic testing.
  Future<void> stampLastClarifiedAt(String todoId, {DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc();
    await (update(todos)..where((t) => t.id.equals(todoId))).write(
        TodosCompanion(
      lastClarifiedAt: Value(ts),
      updatedAt: Value(ts),
    ));
  }

  /// Restores a done or trashed todo to active next-action status.
  Future<void> restore(String todoId) async {
    final ts = DateTime.now().toUtc().toIso8601String();
    await customUpdate(
      'UPDATE todos SET done_at = NULL, intent = ?, updated_at = ? '
      'WHERE id = ?',
      variables: [
        Variable('next'),
        Variable(ts),
        Variable(todoId),
      ],
      updates: {todos},
      updateKind: UpdateKind.update,
    );
  }

  /// Update mutable todo fields (title, notes, energy level, time estimate, due date).
  Future<void> updateFields(
    String todoId, {
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
    await (update(todos)..where((t) => t.id.equals(todoId))).write(companion);
  }
}
