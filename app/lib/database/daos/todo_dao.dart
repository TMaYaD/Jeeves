/// DAO for GTD views: next actions, waiting for, maybe, by-project, by-area.
library;

import 'package:drift/drift.dart';
import 'package:meta/meta.dart';

import '../../models/todo.dart' show Intent, RoutingKind;
import '../gtd_database.dart';
import 'tag_dao.dart' show todoTagIdFor;

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
      '  todos.next_action_text, todos.last_next_action_completion_at, '
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
  /// Also stamps [last_clarified_at] since marking done is a clarifying act.
  ///
  /// [now] is injectable for deterministic testing; defaults to [DateTime.now].
  ///
  /// Returns the number of affected rows (0 if [todoId] not found, 1 on
  /// success). Inbox callers gate state advancement on a non-zero result.
  Future<int> markDone(String todoId, {DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc().toIso8601String();
    return customUpdate(
      'UPDATE todos SET done_at = ?, updated_at = ?, clarified = 1, last_clarified_at = ? '
      'WHERE id = ?',
      variables: [Variable(ts), Variable(ts), Variable(ts), Variable(todoId)],
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
  /// Also stamps [last_clarified_at] since a state transition is a clarifying act.
  ///
  /// [intent] must be one of: next | maybe | trash.
  /// [now] overrides the timestamp used for [updatedAt]; defaults to [DateTime.now()].
  Future<void> setIntent(String todoId, Intent intent, {DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc().toIso8601String();
    await customUpdate(
      'UPDATE todos SET intent = ?, updated_at = ?, last_clarified_at = ? WHERE id = ?',
      variables: [
        Variable(intent.value),
        Variable(ts),
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

  /// Sets [next_action_text] and stamps [last_clarified_at] atomically.
  ///
  /// Used by inbox-clarify (to record the task title as the default action) and
  /// by the review step's "Update next action" action.
  Future<void> setNextActionText(
      String todoId, String text, {DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final normalized = text.trim();
    await (update(todos)..where((t) => t.id.equals(todoId)))
        .write(TodosCompanion(
      nextActionText: Value(normalized.isEmpty ? null : normalized),
      lastClarifiedAt: Value(ts),
      updatedAt: Value(ts),
    ));
  }

  // ---------------------------------------------------------------------------
  // Re-clarification surface (issue #237)
  // ---------------------------------------------------------------------------

  static const _needsReviewWhere = '''
clarified = 1
AND done_at IS NULL
AND intent = 'next'
AND (
  (last_next_action_completion_at IS NOT NULL
   AND (last_clarified_at IS NULL
        OR last_clarified_at < last_next_action_completion_at))
  OR next_action_text IS NULL
  OR TRIM(next_action_text) = ''
)''';

  /// Stream of tasks needing re-clarification: Stale or Actionless per spec.
  ///
  /// Stale: worked on in a session more recently than last clarified.
  /// Actionless: no next action defined (regardless of session history).
  Stream<List<Todo>> watchNeedsReview() {
    return customSelect(
      'SELECT * FROM todos WHERE $_needsReviewWhere ORDER BY created_at',
      variables: [],
      readsFrom: {todos},
    ).watch().map((rows) => rows.map((r) => todos.map(r.data)).toList());
  }

  /// One-shot snapshot of tasks needing re-clarification.
  Future<List<Todo>> getNeedsReview() {
    return customSelect(
      'SELECT * FROM todos WHERE $_needsReviewWhere ORDER BY created_at',
      variables: [],
      readsFrom: {todos},
    ).get().then((rows) => rows.map((r) => todos.map(r.data)).toList());
  }

  /// One-shot count of tasks needing re-clarification.
  @visibleForTesting
  Future<int> getNeedsReviewCount() async {
    final rows = await customSelect(
      'SELECT COUNT(*) AS cnt FROM todos WHERE $_needsReviewWhere',
      variables: [],
      readsFrom: {todos},
    ).get();
    return rows.first.read<int>('cnt');
  }

  /// Clears [done_at], returning the task to an undone state without touching
  /// any other fields. Called when a "mark done" review action is replaced by a
  /// different resolution.
  Future<void> clearDoneAt(String id) async {
    final ts = DateTime.now().toUtc();
    await (update(todos)..where((t) => t.id.equals(id))).write(TodosCompanion(
      doneAt: const Value(null),
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

  /// Returns the IDs of person-typed tags assigned to [todoId].
  Future<Set<String>> getPersonTagIdsForTodo(String todoId) async {
    final rows = await customSelect(
      'SELECT tt.tag_id FROM todo_tags tt '
      'JOIN tags tg ON tg.id = tt.tag_id AND tg.type = ? '
      'WHERE tt.todo_id = ?',
      variables: [Variable('person'), Variable(todoId)],
      readsFrom: {todoTags, tags},
    ).get();
    return rows.map((r) => r.read<String>('tag_id')).toSet();
  }

  /// One-shot check: is [todoId] currently in the re-clarification queue?
  @visibleForTesting
  Future<bool> isNeedsReview(String todoId) async {
    final rows = await customSelect(
      'SELECT 1 FROM todos WHERE id = ? AND $_needsReviewWhere',
      variables: [Variable(todoId)],
      readsFrom: {todos},
    ).get();
    return rows.isNotEmpty;
  }

  /// Sets the person-typed tag associations for [todoId] to exactly
  /// [targetPersonTagIds]: removes person tags currently assigned but not in
  /// the target set, and adds tags in the target set that are not currently
  /// assigned. Non-person tag associations on the todo are left untouched.
  Future<void> setPersonTagsForTodo(
    String todoId,
    Set<String> targetPersonTagIds,
    String userId,
  ) async {
    await transaction(() async {
      final allPersonTagIds = await (select(tags)
            ..where((t) => t.type.equals('person')))
          .map((t) => t.id)
          .get();
      final allPersonTagIdSet = allPersonTagIds.toSet();
      if (allPersonTagIdSet.isEmpty) return;

      final currentRows = await (select(todoTags)
            ..where(
              (tt) => tt.todoId.equals(todoId) & tt.tagId.isIn(allPersonTagIds),
            ))
          .get();
      final currentTagIds = currentRows.map((r) => r.tagId).toSet();

      final toRemove = currentTagIds.difference(targetPersonTagIds);
      final toAdd = targetPersonTagIds
          .intersection(allPersonTagIdSet)
          .difference(currentTagIds);

      if (toRemove.isNotEmpty) {
        await (delete(todoTags)
              ..where(
                (tt) => tt.todoId.equals(todoId) & tt.tagId.isIn(toRemove),
              ))
            .go();
      }
      for (final tagId in toAdd) {
        await into(todoTags).insert(
          TodoTagsCompanion(
            id: Value(todoTagIdFor(todoId, tagId)),
            todoId: Value(todoId),
            tagId: Value(tagId),
            userId: Value(userId),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  /// Single source of truth for routing-transition writes across inbox-clarify
  /// and re-clarification review.
  ///
  /// Each [RoutingKind] in [to] expresses a desired final state for the row's
  /// clarified / intent / done_at columns; the table below is the forward
  /// matrix that [applyRouting] enforces. `last_clarified_at` is stamped on
  /// every call.
  ///
  /// | `to`         | clarified | intent  | done_at | next_action_text          |
  /// |--------------|-----------|---------|---------|---------------------------|
  /// | `nextAction` | true      | 'next'  | clear   | set if `nextActionText`   |
  /// | `waitingFor` | true      | 'next'  | clear   | set if `nextActionText`   |
  /// | `maybe`      | true      | 'maybe' | clear   | leave                     |
  /// | `done`       | true      | leave   | now     | leave                     |
  /// | `trash`      | true      | 'trash' | clear   | leave                     |
  ///
  /// Person-tag associations are normally managed out-of-band (the
  /// PersonTagPicker writes them before the routing call). [applyRouting]
  /// itself touches person tags in two cases, both of which require [userId]:
  ///   1. Caller passes [personTagIds] — the set is written via
  ///      [setPersonTagsForTodo] (used for `waitingFor → waitingFor` with a
  ///      new delegate set).
  ///   2. [from] is [RoutingKind.waitingFor] and [to] is not — person tags
  ///      are cleared, since they are a waitingFor-specific side effect and
  ///      should not trail into other lists.
  /// All other transitions leave person tags untouched, so pre-existing
  /// associations from sync/import survive.
  ///
  /// All writes run inside a single transaction so a failure leaves the row
  /// in its prior state.
  Future<void> applyRouting(
    String todoId, {
    required RoutingKind to,
    RoutingKind? from,
    String? nextActionText,
    Set<String>? personTagIds,
    String? userId,
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final tsIso = ts.toIso8601String();
    await transaction(() async {
      final companion = switch (to) {
        RoutingKind.nextAction || RoutingKind.waitingFor => TodosCompanion(
            clarified: const Value(true),
            intent: const Value('next'),
            doneAt: const Value(null),
            nextActionText: nextActionText != null
                ? Value(_normaliseText(nextActionText))
                : const Value.absent(),
            lastClarifiedAt: Value(ts),
            updatedAt: Value(ts),
          ),
        RoutingKind.maybe => TodosCompanion(
            clarified: const Value(true),
            intent: const Value('maybe'),
            doneAt: const Value(null),
            lastClarifiedAt: Value(ts),
            updatedAt: Value(ts),
          ),
        RoutingKind.done => TodosCompanion(
            clarified: const Value(true),
            doneAt: Value(tsIso),
            lastClarifiedAt: Value(ts),
            updatedAt: Value(ts),
          ),
        RoutingKind.trash => TodosCompanion(
            clarified: const Value(true),
            intent: const Value('trash'),
            doneAt: const Value(null),
            lastClarifiedAt: Value(ts),
            updatedAt: Value(ts),
          ),
      };
      await (update(todos)..where((t) => t.id.equals(todoId))).write(companion);

      if (personTagIds != null) {
        if (userId == null) {
          throw ArgumentError(
            'userId is required when personTagIds is provided',
          );
        }
        await setPersonTagsForTodo(todoId, personTagIds, userId);
      } else if (from == RoutingKind.waitingFor && to != RoutingKind.waitingFor) {
        if (userId == null) {
          throw ArgumentError(
            'userId is required to clear person tags on waitingFor → other transitions',
          );
        }
        await setPersonTagsForTodo(todoId, const <String>{}, userId);
      }
    });
  }

  static String? _normaliseText(String text) {
    final trimmed = text.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Update mutable todo fields (title, notes, energy level, time estimate, due date).
  ///
  /// Title and due-date edits are clarifying acts: they stamp [lastClarifiedAt]
  /// so a stale task does not remain falsely surfaced after such changes.
  ///
  /// To clear a nullable column, pass the matching `clear*` flag (e.g.
  /// `clearTimeEstimate: true`). Passing `null` for the typed parameter is
  /// "no change" so callers don't accidentally null-out fields they're not
  /// editing.
  Future<void> updateFields(
    String todoId, {
    String? title,
    String? notes,
    String? energyLevel,
    int? timeEstimate,
    DateTime? dueDate,
    bool clearEnergyLevel = false,
    bool clearTimeEstimate = false,
    bool clearDueDate = false,
  }) async {
    final ts = DateTime.now().toUtc();
    final shouldStampClarified = title != null || dueDate != null || clearDueDate;
    final companion = TodosCompanion(
      updatedAt: Value(ts),
      lastClarifiedAt: shouldStampClarified ? Value(ts) : const Value.absent(),
      title: title != null ? Value(title) : const Value.absent(),
      notes: notes != null ? Value(notes) : const Value.absent(),
      energyLevel: clearEnergyLevel
          ? const Value(null)
          : energyLevel != null
              ? Value(energyLevel)
              : const Value.absent(),
      timeEstimate: clearTimeEstimate
          ? const Value(null)
          : timeEstimate != null
              ? Value(timeEstimate)
              : const Value.absent(),
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
