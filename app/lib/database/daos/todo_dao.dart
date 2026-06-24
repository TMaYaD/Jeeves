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

  /// SQL fragment excluding the actionless+PersonBlocked quadrant from the
  /// Next List. See [watchNext] for the precise rule; pulled out as a
  /// constant so the predicate is named and shared with any future caller
  /// that needs the same exclusion shape.
  ///
  /// Mirrors the actionless-treatment of `_needsReviewWhere`: a whitespace-
  /// only `next_action_text` is treated as actionless, matching the
  /// `setNextActionText` normalisation that already coerces such writes to
  /// NULL.
  static const _excludeActionlessPersonBlockedClause = '''
(
  (todos.next_action_text IS NOT NULL AND TRIM(todos.next_action_text) != '')
  OR NOT EXISTS (
    SELECT 1 FROM todo_tags tt
    JOIN tags tg ON tg.id = tt.tag_id
    WHERE tt.todo_id = todos.id AND tg.type = 'person'
  )
)''';

  /// Stream of clarified, non-done todos filtered by [intent] and, optionally,
  /// by an AND-set of [tagIds].
  ///
  /// The tag-filter shape (`COUNT(DISTINCT tag_id) = n` over `todo_tags`) is
  /// the single source of truth for "all of these tags" semantics. Callers
  /// like [watchNext] and [watchMaybe] vary only by [intent]; if the
  /// filter ever needs to change (ANY-of-tags, null-handling on the join, …)
  /// the change happens here, once.
  ///
  /// When [excludeActionlessPersonBlocked] is true the query additionally
  /// strips the (no current Action) ∧ (carries Tag(type='person')) quadrant
  /// — used by [watchNext] to enforce the precise Next List rule.
  /// Off by default so other lists (Someday/Maybe, …) keep their semantics.
  ///
  /// Watches `todos` always and `todo_tags` when a tag filter is supplied, so
  /// the stream re-emits when either side changes. The exclusion clause also
  /// reads `tags` (for `tg.type = 'person'`); it is added to `readsFrom` when
  /// active.
  Stream<List<Todo>> _watchByIntentAndTags({
    required Intent intent,
    Set<String> tagIds = const {},
    bool excludeActionlessPersonBlocked = false,
  }) {
    final intentVar = Variable(intent.value);
    final extraWhere = excludeActionlessPersonBlocked
        ? ' AND $_excludeActionlessPersonBlockedClause'
        : '';
    if (tagIds.isEmpty) {
      return customSelect(
        'SELECT * FROM todos '
        'WHERE clarified = 1 AND done_at IS NULL AND intent = ?'
        '$extraWhere '
        'ORDER BY created_at',
        variables: [intentVar],
        readsFrom: excludeActionlessPersonBlocked
            ? {todos, todoTags, tags}
            : {todos},
      ).watch().map((rows) => rows.map((r) => todos.map(r.data)).toList());
    }
    final n = tagIds.length;
    final placeholders = List.filled(n, '?').join(', ');
    return customSelect(
      'SELECT todos.* FROM todos '
      'WHERE todos.clarified = 1 '
      'AND todos.done_at IS NULL '
      'AND todos.intent = ? '
      'AND (SELECT COUNT(DISTINCT tag_id) FROM todo_tags '
      '     WHERE todo_id = todos.id '
      '       AND tag_id IN ($placeholders)) = $n'
      '$extraWhere '
      'ORDER BY todos.created_at',
      variables: [intentVar, ...tagIds.map(Variable.new)],
      readsFrom: excludeActionlessPersonBlocked
          ? {todos, todoTags, tags}
          : {todos, todoTags},
    ).watch().map((rows) => rows.map((r) => todos.map(r.data)).toList());
  }

  /// Stream of Outcomes on the Next List.
  ///
  /// The Next List rule is:
  ///
  /// ```text
  /// Next = intent='next' ∧ clarified ∧ done_at IS NULL ∧
  ///        (next_action_text IS NOT NULL ∨ no PersonBlocker on the Outcome)
  /// ```
  ///
  /// The single excluded quadrant is **actionless** (`next_action_text` null
  /// or whitespace) **AND** PersonBlocked (carries any `Tag(type='person')`)
  /// — that combination is a pure wait and surfaces only on Waiting For. An
  /// Outcome with a current Action (`next_action_text IS NOT NULL`) belongs
  /// on Next regardless of any PersonBlocker: `"call Trixy for a follow up"`
  /// is doable and eligible for engagement; it also surfaces under Waiting
  /// For. This overlap is by design — see CONTEXT.md § Next / Waiting For.
  ///
  /// The earlier `intent != 'maybe'` formulation admitted `intent='trash'`
  /// rows (#278). When [tagIds] is non-empty only todos carrying **all**
  /// specified tags are returned (AND semantics); the actionless+
  /// PersonBlocked exclusion applies under tag-filtering too.
  Stream<List<Todo>> watchNext({Set<String> tagIds = const {}}) {
    return _watchByIntentAndTags(
      intent: Intent.next,
      tagIds: tagIds,
      excludeActionlessPersonBlocked: true,
    );
  }

  /// Stream of "Waiting For" todos.
  ///
  /// Returns clarified, non-done, intent='next' todos that have at least one
  /// person-typed tag. When [tagIds] is non-empty only todos carrying **all**
  /// specified (context/filter) tags are returned (AND semantics).
  ///
  /// Stays bespoke (rather than wrapping [_watchByIntentAndTags]) because the
  /// "at least one person-typed tag" requirement is enforced by a JOIN onto
  /// `tags` filtered by `type='person'` — a JOIN shape the helper does not
  /// model. The tag-filter `COUNT(DISTINCT)` subquery still mirrors the
  /// helper's SQL so semantics stay aligned.
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
    return _watchByIntentAndTags(intent: Intent.maybe, tagIds: tagIds);
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
  ///
  /// Done means "completed and not deleted." Trashed rows are excluded so
  /// the Done list isn't polluted by tasks the user has explicitly removed,
  /// even if a `done_at` timestamp survived the trash transition (#278).
  Stream<List<Todo>> watchDone() {
    return customSelect(
      "SELECT * FROM todos WHERE done_at IS NOT NULL AND intent != 'trash' "
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
  /// Stamps [last_clarified_at]: a due-date edit is a clarifying micro-act
  /// per CONTEXT.md ("Clarification stamps last_clarified_at per micro-act").
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
      lastClarifiedAt: Value(ts.toUtc()),
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
  /// Escape hatch for clarifying micro-acts whose primary write happens on
  /// another table (e.g. person-tag — a PersonBlocker — assignment writes a
  /// row to `todo_tags`, but the Outcome itself needs its clarification
  /// timestamp updated). DAO methods that mutate `todos` directly stamp
  /// internally and do not need this helper.
  ///
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
  OR (
    (next_action_text IS NULL OR TRIM(next_action_text) = '')
    AND NOT EXISTS (
      SELECT 1 FROM todo_tags tt
      JOIN tags tg ON tg.id = tt.tag_id
      WHERE tt.todo_id = todos.id AND tg.type = 'person'
    )
  )
)''';

  /// Stream of tasks needing re-clarification: Stale or Actionless per spec.
  ///
  /// Stale: worked on in a session more recently than last clarified.
  /// Actionless: no next action defined AND not delegated. Delegated tasks
  /// (carrying any person-typed tag) are excluded from the actionless branch —
  /// their cadence belongs to the weekly Waiting For review, not the daily
  /// re-clarification surface.
  Stream<List<Todo>> watchNeedsReview() {
    return customSelect(
      'SELECT * FROM todos WHERE $_needsReviewWhere ORDER BY created_at',
      variables: [],
      readsFrom: {todos, todoTags, tags},
    ).watch().map((rows) => rows.map((r) => todos.map(r.data)).toList());
  }

  /// One-shot snapshot of active next-action todos that carry **no** person-
  /// typed tag. Used by the Weekly Review wizard's Next Actions step; the
  /// person-tag exclusion keeps it disjoint from Waiting For's snapshot so
  /// each task surfaces in at most one wizard step.
  Future<List<Todo>> getNextExcludingPersonTagged() {
    return customSelect(
      'SELECT todos.* FROM todos '
      'WHERE todos.clarified = 1 '
      'AND todos.done_at IS NULL '
      'AND todos.intent = ? '
      'AND NOT EXISTS ('
      '  SELECT 1 FROM todo_tags tt '
      '  JOIN tags tg ON tg.id = tt.tag_id '
      '  WHERE tt.todo_id = todos.id AND tg.type = ?'
      ') '
      'ORDER BY todos.created_at',
      variables: [Variable('next'), Variable('person')],
      readsFrom: {todos, todoTags, tags},
    ).get().then((rows) => rows.map((r) => todos.map(r.data)).toList());
  }

  /// One-shot snapshot of tasks needing re-clarification.
  Future<List<Todo>> getNeedsReview() {
    return customSelect(
      'SELECT * FROM todos WHERE $_needsReviewWhere ORDER BY created_at',
      variables: [],
      readsFrom: {todos, todoTags, tags},
    ).get().then((rows) => rows.map((r) => todos.map(r.data)).toList());
  }

  /// One-shot count of tasks needing re-clarification.
  @visibleForTesting
  Future<int> getNeedsReviewCount() async {
    final rows = await customSelect(
      'SELECT COUNT(*) AS cnt FROM todos WHERE $_needsReviewWhere',
      variables: [],
      readsFrom: {todos, todoTags, tags},
    ).get();
    return rows.first.read<int>('cnt');
  }

  /// Clears [done_at], returning the task to an undone state without touching
  /// any other fields. Called when a "mark done" review action is replaced by a
  /// different resolution.
  ///
  /// Stamps [last_clarified_at]: reverting an Outcome's completion is a
  /// structural decision about the Outcome, the dual of marking it done —
  /// both ends of the Completion axis are clarifying micro-acts per CONTEXT.md.
  Future<void> clearDoneAt(String id) async {
    final ts = DateTime.now().toUtc();
    await (update(todos)..where((t) => t.id.equals(id))).write(TodosCompanion(
      doneAt: const Value(null),
      lastClarifiedAt: Value(ts),
      updatedAt: Value(ts),
    ));
  }

  /// Restores a done or trashed todo to active next-action status.
  ///
  /// Stamps [last_clarified_at]: restoring is an Intent edit (sets
  /// intent='next', clears done_at) — a clarifying micro-act per CONTEXT.md.
  Future<void> restore(String todoId) async {
    final ts = DateTime.now().toUtc().toIso8601String();
    await customUpdate(
      'UPDATE todos SET done_at = NULL, intent = ?, updated_at = ?, '
      'last_clarified_at = ? WHERE id = ?',
      variables: [
        Variable('next'),
        Variable(ts),
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

  /// One-shot batched lookup of person tags for every todo in [todoIds].
  /// Returns a map keyed by todo id; todos with no person tag are absent.
  /// Used by the Weekly Review wizard to render delegate names alongside
  /// each waiting-for item without spawning one DAO call per item.
  Future<Map<String, List<Tag>>> getPersonTagsForTodos(
      Set<String> todoIds) async {
    if (todoIds.isEmpty) return const {};
    final placeholders = List.filled(todoIds.length, '?').join(', ');
    final rows = await customSelect(
      'SELECT tt.todo_id, tg.id AS tag_id, tg.name AS tag_name, '
      '       tg.color AS tag_color, tg.type AS tag_type, '
      '       tg.user_id AS tag_user_id '
      'FROM todo_tags tt '
      'JOIN tags tg ON tg.id = tt.tag_id AND tg.type = ? '
      'WHERE tt.todo_id IN ($placeholders) '
      'ORDER BY tg.name',
      variables: [Variable('person'), ...todoIds.map(Variable.new)],
      readsFrom: {todoTags, tags},
    ).get();
    final result = <String, List<Tag>>{};
    for (final row in rows) {
      final tag = Tag(
        id: row.read<String>('tag_id'),
        name: row.read<String>('tag_name'),
        color: row.readNullable<String>('tag_color'),
        type: row.read<String>('tag_type'),
        userId: row.read<String>('tag_user_id'),
      );
      (result[row.read<String>('todo_id')] ??= <Tag>[]).add(tag);
    }
    return result;
  }

  /// One-shot check: is [todoId] currently in the re-clarification queue?
  @visibleForTesting
  Future<bool> isNeedsReview(String todoId) async {
    final rows = await customSelect(
      'SELECT 1 FROM todos WHERE id = ? AND $_needsReviewWhere',
      variables: [Variable(todoId)],
      readsFrom: {todos, todoTags, tags},
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
  /// | `trash`      | true      | 'trash' | leave   | leave                     |
  ///
  /// Cleanup rule: any non-Done, non-Trash route clears `done_at` if set, so
  /// promoting a previously-completed task back to active state can't leave
  /// a stale `done_at` behind. Done refreshes the timestamp; Trash leaves it
  /// alone so a completion record is preserved through soft-delete.
  ///
  /// Person-tag associations are orthogonal to the intent axis:
  /// [applyRouting] only touches them when the caller explicitly passes
  /// [personTagIds] (in which case [userId] is required), so a delegated
  /// task can change intent (`next → someday`, `next → trash`, …) without
  /// silently losing its person-tag attachments. Person tags are managed
  /// out-of-band by [setPersonTagsForTodo] / the PersonTagPicker.
  ///
  /// All writes run inside a single transaction so a failure leaves the row
  /// in its prior state.
  Future<void> applyRouting(
    String todoId, {
    required RoutingKind to,
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
      }
    });
  }

  static String? _normaliseText(String text) {
    final trimmed = text.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Update mutable todo fields (title, notes, energy level, time estimate, due date).
  ///
  /// Every field this method can change is a clarifying micro-act per
  /// CONTEXT.md (title / notes / due-date edits, and Action cursor-fields
  /// energy / time-estimate — Actions are first-class per ADR-0001 and their
  /// mutations stamp). Any non-no-op call therefore stamps [lastClarifiedAt].
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
    bool clearNotes = false,
    bool clearEnergyLevel = false,
    bool clearTimeEstimate = false,
    bool clearDueDate = false,
  }) async {
    final ts = DateTime.now().toUtc();
    // A no-op call (no field provided, no clear flag set) must not stamp —
    // stamping requires an actual mutation. Any provided field or clear flag
    // means the user is actively editing the Outcome and the stamp is owed.
    final hasMutation = title != null ||
        notes != null ||
        energyLevel != null ||
        timeEstimate != null ||
        dueDate != null ||
        clearNotes ||
        clearEnergyLevel ||
        clearTimeEstimate ||
        clearDueDate;
    final companion = TodosCompanion(
      updatedAt: Value(ts),
      lastClarifiedAt: hasMutation ? Value(ts) : const Value.absent(),
      title: title != null ? Value(title) : const Value.absent(),
      notes: clearNotes
          ? const Value(null)
          : notes != null
              ? Value(notes)
              : const Value.absent(),
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
