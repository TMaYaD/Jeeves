/// DAO for GTD views: next actions, waiting for, maybe, by-project, by-area.
library;

import 'package:drift/drift.dart';

import '../../models/todo.dart' show Intent, RoutingKind;
import '../../sync/collection_codecs.dart';
import '../gtd_database.dart';
import 'action_dao.dart' show ActionDao;
import 'capture_dao.dart' show captureOutcomeIdFor;
import 'tag_dao.dart' show todoTagIdFor;
import 'time_log_dao.dart' show TimeLogDao;

part 'todo_dao.g.dart';

@DriftAccessor(tables: [Todos, Tags, TodoTags, Actions])
class TodoDao extends DatabaseAccessor<GtdDatabase> with _$TodoDaoMixin {
  TodoDao(super.db);

  /// Describe an Outcome write on the op-log seam. Only the columns this act
  /// actually changed: field-grain merge is what lets one device's `notes` edit
  /// and another's Action write both survive, and a whole-row re-assertion
  /// under a fresh clock would destroy that.
  void _captureTodo(String todoId, Map<String, Object?> fields) {
    if (fields.isEmpty) return;
    attachedDatabase.opCapture.write(
      collection: todosCollection,
      entityId: todoId,
      fields: fields,
    );
  }

  // ---------------------------------------------------------------------------
  // Shared Todo read projection (ADR-0001 story 7 — Action-grain metadata)
  // ---------------------------------------------------------------------------

  /// D2 read rule for `energy_level`: the current Action's value, else the
  /// Outcome column. The COALESCE fallback keeps Actionless Outcomes and
  /// never-migrated legacy stores (no `actions` rows) displaying their stored
  /// value — no data loss, no blank-out — and, under the write-side mirror
  /// (D1) + startup sweep, resolves to the current Action's value once one
  /// exists. [t] is the `todos` table's SQL alias in the enclosing query
  /// (`'todos'` or `'t'`).
  static String effectiveEnergyLevelSql(String t) =>
      'COALESCE('
      "${ActionDao.currentActionColumnSubquery('energy_level', '$t.id')}, "
      '$t.energy_level)';

  /// D2 read rule for `time_estimate`; see [effectiveEnergyLevelSql].
  static String effectiveTimeEstimateSql(String t) =>
      'COALESCE('
      "${ActionDao.currentActionColumnSubquery('time_estimate', '$t.id')}, "
      '$t.time_estimate)';

  /// The full `todos` column projection every Todo-producing query selects, so
  /// `todos.map(row.data)` hydrates the [Todo] model with **Action-grain**
  /// `energy_level` / `time_estimate` (D2) and live-derived `time_spent_minutes`
  /// (issue #480) — leaving UI and providers untouched. The raw
  /// `todos.energy_level` / `time_estimate` columns remain the write mirror and
  /// the Actionless draft store (D1/D3). `last_next_action_completion_at` is
  /// live — stamped by the focus-session close and read by the
  /// re-clarification predicate. [t] is the `todos` table's SQL alias in the
  /// enclosing query.
  ///
  /// Queries carrying this projection must list `actions` and `time_logs` in
  /// `readsFrom` so a synced Action or TimeLog write re-emits their watchers.
  static String todoProjectionSql(String t) =>
      '$t.id, $t.title, $t.notes, $t.priority, $t.due_date, $t.created_at, '
      '$t.updated_at, $t.done_at, $t.clarified, $t.intent, '
      '${effectiveTimeEstimateSql(t)} AS time_estimate, '
      '${effectiveEnergyLevelSql(t)} AS energy_level, '
      '$t.capture_source, $t.location_id, $t.user_id, $t.last_clarified_at, '
      '${TimeLogDao.totalMinutesSubquery('$t.id')} AS time_spent_minutes, '
      '$t.last_next_action_completion_at';

  // ---------------------------------------------------------------------------
  // Single-todo helpers
  // ---------------------------------------------------------------------------

  /// Returns a single todo by [todoId], or null if not found.
  ///
  /// Carries the [todoProjectionSql] so the returned [Todo]'s `energyLevel` /
  /// `timeEstimate` resolve to the current Action (D2) — the task-detail
  /// editors read these, and their edits mirror back through
  /// [updateFields], so read and write stay on the same grain.
  Future<Todo?> getTodo(String todoId) {
    return customSelect(
      'SELECT ${todoProjectionSql('todos')} FROM todos WHERE todos.id = ?',
      variables: [Variable(todoId)],
      readsFrom: {todos, actions, attachedDatabase.timeLogs},
    ).getSingleOrNull().then((r) => r == null ? null : todos.map(r.data));
  }

  /// Stream that re-emits a single todo whenever it (or its current Action)
  /// changes; hydrated with Action-grain metadata via [todoProjectionSql].
  Stream<Todo?> watchTodo(String todoId) {
    return customSelect(
      'SELECT ${todoProjectionSql('todos')} FROM todos WHERE todos.id = ?',
      variables: [Variable(todoId)],
      readsFrom: {todos, actions, attachedDatabase.timeLogs},
    ).watchSingleOrNull().map((r) => r == null ? null : todos.map(r.data));
  }

  // ---------------------------------------------------------------------------
  // GTD list watchers
  // ---------------------------------------------------------------------------

  /// SQL fragment matching Outcomes that have a current Action — the entity is
  /// the only next-action grain (ADR-0001 story 3). Only `role =
  /// 'current'` counts: a `planned` Action is not engageable (ADR-0004) and a
  /// `superseded` one is history.
  ///
  /// No `TRIM` guard: the Action entity's existence *is* the evidence, and
  /// blank Action text is unrepresentable — [ActionDao.applySetCurrentAction]
  /// rejects it and the backfills never mint it.
  static const _hasCurrentActionClause = '''
EXISTS (
  SELECT 1 FROM actions
  WHERE actions.outcome_id = todos.id AND actions.role = 'current'
)''';

  /// SQL fragment excluding the actionless+PersonBlocked quadrant from the
  /// Next List. See [watchNext] for the precise rule; pulled out as a
  /// constant so the predicate is named and shared with any future caller
  /// that needs the same exclusion shape.
  static const _excludeActionlessPersonBlockedClause = '''
(
  $_hasCurrentActionClause
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
  /// reads `tags` (for `tg.type = 'person'`) and `actions` (for the current
  /// Action); both are added to `readsFrom` when active, so an Action written
  /// here or synced in from another device re-emits the list.
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
        'SELECT ${todoProjectionSql('todos')} FROM todos '
        'WHERE clarified = 1 AND done_at IS NULL AND intent = ?'
        '$extraWhere '
        'ORDER BY created_at',
        variables: [intentVar],
        readsFrom: excludeActionlessPersonBlocked
            ? {todos, todoTags, tags, actions, attachedDatabase.timeLogs}
            : {todos, actions, attachedDatabase.timeLogs},
      ).watch().map((rows) => rows.map((r) => todos.map(r.data)).toList());
    }
    final n = tagIds.length;
    final placeholders = List.filled(n, '?').join(', ');
    return customSelect(
      'SELECT ${todoProjectionSql('todos')} FROM todos '
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
          ? {todos, todoTags, tags, actions, attachedDatabase.timeLogs}
          : {todos, todoTags, actions, attachedDatabase.timeLogs},
    ).watch().map((rows) => rows.map((r) => todos.map(r.data)).toList());
  }

  /// Stream of Outcomes on the Next List.
  ///
  /// The Next List rule is:
  ///
  /// ```text
  /// Next = intent='next' ∧ clarified ∧ done_at IS NULL ∧
  ///        (has a current Action ∨ no PersonBlocker on the Outcome)
  /// ```
  ///
  /// "Has a current Action" is answered from the `actions` table — an
  /// `actions` row for this Outcome with `role='current'` (ADR-0001 story 3).
  /// The List still *contains* Outcomes; only the predicate's evidence source
  /// is the Action entity.
  ///
  /// The single excluded quadrant is **actionless** (no current Action row)
  /// **AND** PersonBlocked (carries any `Tag(type='person')`)
  /// — that combination is a pure wait and surfaces only on Waiting For. An
  /// Outcome with a current Action belongs
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
        'SELECT DISTINCT ${todoProjectionSql('todos')} FROM todos '
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
        readsFrom: {todos, todoTags, tags, actions, attachedDatabase.timeLogs},
      ).watch().map((rows) => rows.map((row) => todos.map(row.data)).toList());
    }
    final n = tagIds.length;
    final placeholders = List.filled(n, '?').join(', ');
    return customSelect(
      'SELECT DISTINCT ${todoProjectionSql('todos')} FROM todos '
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
      readsFrom: {todos, todoTags, tags, actions, attachedDatabase.timeLogs},
    ).watch().map((rows) => rows.map((row) => todos.map(row.data)).toList());
  }

  /// Stream of todos grouped by person-tag.
  ///
  /// Each todo appears once per person-tag it carries.  A todo with two
  /// person-tags appears in two entries.  Results are ordered by tag name
  /// then todo creation date — insertion order matches the grouped view.
  Stream<Map<Tag, List<Todo>>> watchPersonTaggedGrouped() {
    return customSelect(
      // Shared Todo projection (Action-grain energy/time via D2, live-derived
      // time_spent_minutes per #480) plus the person-tag columns this grouped
      // view needs.
      'SELECT ${todoProjectionSql('todos')}, '
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
      readsFrom: {todos, todoTags, tags, actions, attachedDatabase.timeLogs},
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

  // ---------------------------------------------------------------------------
  // Done
  // ---------------------------------------------------------------------------

  /// Marks [todoId] as done by setting [done_at] to the current UTC timestamp.
  /// Also stamps [last_clarified_at] since marking done is a clarifying act.
  ///
  /// Achieving the Outcome also **terminates its current Action** as `done`
  /// (ADR-0001 story 4): the user finished that step in the act of finishing
  /// the Outcome, so the Action row records a real completion rather than a
  /// supersession. `planned` rows are left untouched as history, and the
  /// cursor is cleared with the Action-side write so both sides keep agreeing.
  ///
  /// [now] is injectable for deterministic testing; defaults to [DateTime.now].
  ///
  /// Returns the number of affected rows (0 if [todoId] not found, 1 on
  /// success). Inbox callers gate state advancement on a non-zero result.
  Future<int> markDone(String todoId, {DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final tsIso = ts.toIso8601String();
    late final int affected;
    var actionTerminated = false;
    var logChanged = false;
    await attachedDatabase.capturing(() => transaction(() async {
      affected = await customUpdate(
        'UPDATE todos SET done_at = ?, updated_at = ?, clarified = 1, last_clarified_at = ? '
        'WHERE id = ?',
        variables: [
          Variable(tsIso),
          Variable(tsIso),
          Variable(tsIso),
          Variable(todoId),
        ],
        updates: {todos},
        updateKind: UpdateKind.update,
      );
      if (affected > 0) {
        _captureTodo(todoId, {
          // `done_at` is a TEXT column: its stored string travels opaque.
          'done_at': tsIso,
          'updated_at': encodeInstant(ts),
          'clarified': true,
          'last_clarified_at': encodeInstant(ts),
        });
      }
      final effect = await attachedDatabase.actionDao
          .applyCompleteCurrentAction(todoId, ts: ts);
      actionTerminated = effect.changed;
      logChanged = effect.logChanged;
    }));
    if (actionTerminated) attachedDatabase.notifyActionsViewWrite();
    // Completing the Outcome closes the current Action's open TimeLog (#476);
    // the `time_logs` view needs the same explicit post-commit notify (ADR-0010).
    if (logChanged) attachedDatabase.notifyTimeLogsViewWrite();
    return affected;
  }

  /// Stream of completed todos, ordered by [done_at] descending.
  ///
  /// Done means "completed and not deleted." Trashed rows are excluded so
  /// the Done list isn't polluted by tasks the user has explicitly removed,
  /// even if a `done_at` timestamp survived the trash transition (#278).
  Stream<List<Todo>> watchDone() {
    return customSelect(
      'SELECT ${todoProjectionSql('todos')} FROM todos '
      "WHERE done_at IS NOT NULL AND intent != 'trash' "
      'ORDER BY done_at DESC',
      variables: [],
      readsFrom: {todos, actions, attachedDatabase.timeLogs},
    ).watch().map((rows) => rows.map((r) => todos.map(r.data)).toList());
  }

  // ---------------------------------------------------------------------------
  // Trash
  // ---------------------------------------------------------------------------

  /// Stream of trashed todos — the Trash List surface.
  ///
  /// Membership per CONTEXT.md § GTD Core: `Intent = trash`, regardless of
  /// Completion. A completed-then-trashed Outcome surfaces here and only
  /// here — [watchDone] excludes trashed rows, keeping Done and Trash
  /// disjoint (#278).
  ///
  /// Ordering approximates "newest-trashed first" without a dedicated
  /// `trashed_at` column: every write path into trash stamps
  /// `last_clarified_at` ([setIntent], [applyRouting]), and any later
  /// clarifying act on a trashed row either restores it out of Trash or is
  /// a rare direct edit, so the stamp is a faithful proxy for the trashing
  /// act. `updated_at` / `created_at` are fallbacks for legacy rows that
  /// predate the stamp. All three columns store ISO-8601 text, so
  /// lexicographic DESC is chronological.
  Stream<List<Todo>> watchTrash() {
    return customSelect(
      'SELECT ${todoProjectionSql('todos')} FROM todos '
      "WHERE intent = 'trash' "
      'ORDER BY COALESCE(last_clarified_at, updated_at, created_at) DESC',
      variables: [],
      readsFrom: {todos, actions, attachedDatabase.timeLogs},
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
      'SELECT ${todoProjectionSql('todos')} FROM todos '
      'WHERE id IN ($placeholders) '
      'ORDER BY created_at',
      variables: [...ids.map(Variable.new)],
      readsFrom: {todos, actions, attachedDatabase.timeLogs},
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
    // Normalised once: the op carries `encodeInstant(ts)`, which is UTC, so a
    // caller passing a local `now` would otherwise leave `updated_at` and its
    // op disagreeing.
    final ts = (now ?? DateTime.now()).toUtc();
    await attachedDatabase.capturing(() async {
      await (update(todos)..where((t) => t.id.equals(id))).write(TodosCompanion(
        // Store UTC so Drift's storeDateTimeAsText path emits a standard
        // ISO-8601 string (no leading-space offset). An offset-bearing spelling
        // like "...000 +05:30" is not what the op log's instant encoding
        // accepts, so a local-time row would author an op nothing can read
        // back (`sync/collection_codecs.dart`).
        dueDate: Value(newDueDate.toUtc()),
        lastClarifiedAt: Value(ts),
        updatedAt: Value(ts),
      ));
      _captureTodo(id, {
        'due_date': encodeInstant(newDueDate),
        'last_clarified_at': encodeInstant(ts),
        'updated_at': encodeInstant(ts),
      });
      attachedDatabase.notifyTodosViewWrite();
    });
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
    final tsInstant = (now ?? DateTime.now()).toUtc();
    final ts = tsInstant.toIso8601String();
    await attachedDatabase.capturing(() async {
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
      // Trash is a plain field write on a live entity — the Outcome stays
      // alive, in Trash. The only hard delete is [deleteOutcome].
      _captureTodo(todoId, {
        'intent': intent.value,
        'updated_at': encodeInstant(tsInstant),
        'last_clarified_at': encodeInstant(tsInstant),
      });
    });
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
    await attachedDatabase.capturing(() async {
      await (update(todos)..where((t) => t.id.equals(todoId))).write(
          TodosCompanion(
        lastClarifiedAt: Value(ts),
        updatedAt: Value(ts),
      ));
      _captureTodo(todoId, {
        'last_clarified_at': encodeInstant(ts),
        'updated_at': encodeInstant(ts),
      });
      attachedDatabase.notifyTodosViewWrite();
    });
  }

  /// Writes the Outcome's `current` Action from a single phrase and stamps
  /// [last_clarified_at] atomically (ADR-0001 story 2).
  ///
  /// Used by inbox-clarify (to record the task title as the default action) and
  /// by the review step's "Update next action" action.
  ///
  /// This is the **one-field** surface — one phrase in, the `current` Action
  /// out — and it writes only `actions` plus the Outcome's clarification
  /// stamp; no Outcome column holds a next-action phrase (ADR-0022, ADR-0024).
  /// A non-blank text sets/edits the `current` Action; a blank text clears it
  /// (the blank→Actionless normalisation, expressed on the Action side as a
  /// supersession with no replacement).
  Future<void> setCurrentActionText(
      String todoId, String text, {DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final normalized = text.trim();
    final logChanged = await attachedDatabase.capturing(() => transaction(
        () => _applySetCurrentActionText(todoId, normalized, ts)));
    // The GTD lists read across `todos` and `actions`, so a watcher naming one
    // must hear about a write to the other; notify both explicitly rather than
    // relying on Drift's per-table invalidation (#342, ADR-0010).
    attachedDatabase.notifyTodosViewWrite();
    attachedDatabase.notifyActionsViewWrite();
    // A blank text supersedes the current Action, closing its open TimeLog
    // (#476); `time_logs` is a view too, so it needs the same explicit notify.
    if (logChanged) attachedDatabase.notifyTimeLogsViewWrite();
  }

  /// The **atomic** actionless-mirror primitive (issue #501): check whether the
  /// Outcome is Actionless and — only if it is — write [text] as its next
  /// action, both inside **one** transaction. Returns `true` iff it wrote.
  ///
  /// The check reads the `current` Action via [ActionDao.getCurrentAction],
  /// which runs on this transaction's executor (Drift zone routing), so a
  /// `current` Action landed by sync cannot slip between the check and the
  /// write. This is the single-call replacement for the read-then-write TOCTOU
  /// the ClarifyCard title-mirror used to run across two awaits: an Outcome the
  /// user has already given a deliberate phrase (a `current` Action exists) is
  /// left untouched, never clobbered by a mirrored title.
  ///
  /// Write path: identical to [setCurrentActionText] on an Actionless Outcome —
  /// the same Action write, stamped with one shared [ts], and the same
  /// post-commit view-notifies. Skip path (a `current` Action exists): no
  /// writes, no stamp, no convergence, no notify.
  ///
  /// Blank [text] is a caller error (the mirror only fires with a non-blank
  /// title), mirroring [ActionDao.setCurrentAction]'s contract.
  Future<bool> setCurrentActionTextIfActionless(
      String todoId, String text, {DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final normalized = text.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(
        text,
        'text',
        'setCurrentActionTextIfActionless requires non-blank text',
      );
    }
    var logChanged = false;
    final wrote = await attachedDatabase.capturing(() => transaction(() async {
      final current = await attachedDatabase.actionDao.getCurrentAction(todoId);
      if (current != null) return false;
      // Non-blank text here, so this never supersedes — logChanged stays false.
      logChanged = await _applySetCurrentActionText(todoId, normalized, ts);
      return true;
    }));
    if (wrote) {
      // See [setCurrentActionText]: view writes report changes()==0 (#342, ADR-0010).
      attachedDatabase.notifyTodosViewWrite();
      attachedDatabase.notifyActionsViewWrite();
      if (logChanged) attachedDatabase.notifyTimeLogsViewWrite();
    }
    return wrote;
  }

  /// Transaction body shared by [setCurrentActionText] and
  /// [setCurrentActionTextIfActionless]: the Action write and the
  /// `last_clarified_at` / `updated_at` stamp, encoded once. Runs inside the
  /// caller's transaction; the caller notifies after commit. [normalized] is
  /// already trimmed — blank makes the Outcome Actionless (the blank→NULL
  /// normalisation, expressed as a supersession with no replacement).
  ///
  /// The stamp is written here rather than left to [ActionDao] because these
  /// surfaces stamp even when the Action write is a no-op (re-submitting the
  /// identical phrase is still a clarifying micro-act).
  ///
  /// Returns whether a `time_logs` row changed (the blank→supersede path closes
  /// the current Action's open log, issue #476) so the caller can fire the
  /// TimeLog view notification after commit (ADR-0010).
  Future<bool> _applySetCurrentActionText(
      String todoId, String normalized, DateTime ts) async {
    await (update(todos)..where((t) => t.id.equals(todoId)))
        .write(TodosCompanion(
      lastClarifiedAt: Value(ts),
      updatedAt: Value(ts),
    ));
    _captureTodo(todoId, {
      'last_clarified_at': encodeInstant(ts),
      'updated_at': encodeInstant(ts),
    });
    if (normalized.isEmpty) {
      final effect = await attachedDatabase.actionDao
          .applySupersedeCurrentAction(todoId, ts: ts);
      return effect.logChanged;
    }
    await attachedDatabase.actionDao
        .applySetCurrentAction(todoId, normalized, ts: ts);
    return false;
  }

  // ---------------------------------------------------------------------------
  // Re-clarification surface (issue #237)
  // ---------------------------------------------------------------------------

  /// The latest **Action termination** for the Outcome: the `done_at` of its
  /// most recently completed Action (`updated_at` / `created_at` only as
  /// fallbacks for a foreign row that arrived without one).
  ///
  /// `superseded` rows are deliberately excluded (ADR-0001 story 4). Every
  /// app-side supersession stamps `last_clarified_at` with the same timestamp
  /// it writes to the retired row, so `last_clarified_at < updated_at` is never
  /// true for an honest one; the only `superseded` rows that could outrun the
  /// stamp are the non-stamping *repairs* (multi-current convergence, the
  /// startup sweep), and reading those as engagement would flip an Outcome
  /// Stale on repair alone.
  static const _latestActionTerminationClause = '''
(SELECT MAX(COALESCE(actions.done_at, actions.updated_at, actions.created_at))
 FROM actions
 WHERE actions.outcome_id = todos.id AND actions.role = 'done')''';

  static const _needsReviewWhere = '''
clarified = 1
AND done_at IS NULL
AND intent = 'next'
AND (
  (last_next_action_completion_at IS NOT NULL
   AND (last_clarified_at IS NULL
        OR last_clarified_at < last_next_action_completion_at))
  OR ($_latestActionTerminationClause IS NOT NULL
      AND (last_clarified_at IS NULL
           OR last_clarified_at < $_latestActionTerminationClause))
  OR (
    NOT $_hasCurrentActionClause
    AND NOT EXISTS (
      SELECT 1 FROM todo_tags tt
      JOIN tags tg ON tg.id = tt.tag_id
      WHERE tt.todo_id = todos.id AND tg.type = 'person'
    )
  )
)''';

  /// One-shot snapshot of active next-action todos that carry **no** person-
  /// typed tag. Used by the Weekly Review wizard's Next Actions step; the
  /// person-tag exclusion keeps it disjoint from Waiting For's snapshot so
  /// each task surfaces in at most one wizard step.
  Future<List<Todo>> getNextExcludingPersonTagged() {
    return customSelect(
      'SELECT ${todoProjectionSql('todos')} FROM todos '
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
      readsFrom: {todos, todoTags, tags, actions, attachedDatabase.timeLogs},
    ).get().then((rows) => rows.map((r) => todos.map(r.data)).toList());
  }

  /// Outcomes whose title contains [query], case-insensitively — the match
  /// behind the n-m clarify surface's unified capture-to-Outcome field.
  ///
  /// Restricted to live Outcomes: trashed ones (`intent = 'trash'`) and
  /// achieved ones (`done_at IS NOT NULL`) are excluded, because merging a
  /// fresh Capture into work the user has discarded or already finished is
  /// never the verdict they meant. Ordered by title so the same query always
  /// offers the same rows in the same order; [limit] keeps the suggestion list
  /// short enough to scan.
  Future<List<Todo>> searchOutcomesByTitle(String query, {int limit = 8}) {
    final term = query.trim();
    if (term.isEmpty) return Future.value(const []);
    // Escape the LIKE wildcards so a user typing `%` or `_` searches for that
    // character rather than matching everything.
    final escaped =
        term.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');
    return customSelect(
      'SELECT ${todoProjectionSql('todos')} FROM todos '
      "WHERE todos.title LIKE ? ESCAPE '\\' "
      'AND todos.done_at IS NULL '
      "AND (todos.intent IS NULL OR todos.intent != 'trash') "
      'ORDER BY todos.title '
      'LIMIT ?',
      variables: [Variable('%$escaped%'), Variable<int>(limit)],
      readsFrom: {todos, actions, attachedDatabase.timeLogs},
    ).get().then((rows) => rows.map((r) => todos.map(r.data)).toList());
  }

  /// One-shot snapshot of tasks needing re-clarification: Stale or Actionless
  /// per spec.
  ///
  /// Stale: engaged with more recently than last clarified, read from two
  /// independent signals. `last_next_action_completion_at` means "worked on in
  /// a session" and is stamped once, at session close, by the Review surface;
  /// [_latestActionTerminationClause] means "an Action was completed" and comes
  /// from the Action rows themselves (ADR-0001 story 4), so completing the
  /// current Action surfaces the Outcome even when no session ever closed.
  /// Actionless: no current Action row AND not delegated. Delegated tasks
  /// (carrying any person-typed tag) are excluded from the actionless branch —
  /// their cadence belongs to the weekly Waiting For review, not the daily
  /// re-clarification surface.
  Future<List<Todo>> getNeedsReview() {
    return customSelect(
      'SELECT ${todoProjectionSql('todos')} FROM todos '
      'WHERE $_needsReviewWhere ORDER BY created_at',
      variables: [],
      readsFrom: {todos, todoTags, tags, actions, attachedDatabase.timeLogs},
    ).get().then((rows) => rows.map((r) => todos.map(r.data)).toList());
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

  /// Sets the person-typed tag associations for [todoId] to exactly
  /// [targetPersonTagIds]: removes person tags currently assigned but not in
  /// the target set, and adds tags in the target set that are not currently
  /// assigned. Non-person tag associations on the todo are left untouched.
  Future<void> setPersonTagsForTodo(
    String todoId,
    Set<String> targetPersonTagIds,
    String userId,
  ) async {
    await attachedDatabase.capturing(() => transaction(() async {
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
        for (final tagId in toRemove) {
          // Unassignment is a tombstone op, never row absence.
          attachedDatabase.opCapture.tombstone(
            collection: todoTagsCollection,
            entityId: todoTagIdFor(todoId, tagId),
          );
        }
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
        attachedDatabase.opCapture.write(
          collection: todoTagsCollection,
          entityId: todoTagIdFor(todoId, tagId),
          fields: {'todo_id': todoId, 'tag_id': tagId, 'user_id': userId},
        );
      }
    }));
  }

  /// [setPersonTagsForTodo] plus a `last_clarified_at` stamp, in one
  /// transaction. Choosing a task's delegates is a single clarifying act, so
  /// the two writes must land together: a stamp that fails after the tag
  /// replacement would leave the new delegate set wearing the old clarified
  /// moment, and the task would sort as if it had never been revisited.
  Future<void> setPersonTagsAndStamp(
    String todoId,
    Set<String> targetPersonTagIds,
    String userId, {
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc();
    await attachedDatabase.capturing(() async {
      await transaction(() async {
        await setPersonTagsForTodo(todoId, targetPersonTagIds, userId);
        // Stamped inline rather than through [stampLastClarifiedAt]: that
        // method notifies view watchers itself, and firing that mid-transaction
        // would have them re-read pre-commit state. Notify once below, after
        // commit.
        await (update(todos)..where((t) => t.id.equals(todoId))).write(
          TodosCompanion(
            lastClarifiedAt: Value(ts),
            updatedAt: Value(ts),
          ),
        );
        _captureTodo(todoId, {
          'last_clarified_at': encodeInstant(ts),
          'updated_at': encodeInstant(ts),
        });
      });
      // Person-tag edits move `todo_tags`, which the Outcome surfaces read
      // alongside `todos` — so both groups are notified (ADR-0010).
      attachedDatabase.notifyTodosViewWrite(includeTodoTags: true);
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
  /// | `to`         | clarified | intent  | done_at | current Action           |
  /// |--------------|-----------|---------|---------|--------------------------|
  /// | `nextAction` | true      | 'next'  | clear   | set if `actionText`      |
  /// | `waitingFor` | true      | 'next'  | clear   | set if `actionText`      |
  /// | `maybe`      | true      | 'maybe' | clear   | leave                    |
  /// | `done`       | true      | leave   | now     | completed                |
  /// | `trash`      | true      | 'trash' | leave   | leave                    |
  ///
  /// Cleanup rule: any non-Done, non-Trash route clears `done_at` if set, so
  /// promoting a previously-completed task back to active state can't leave
  /// a stale `done_at` behind. Done refreshes the timestamp; Trash leaves it
  /// alone so a completion record is preserved through soft-delete.
  ///
  /// Done also terminates the Outcome's current Action as `done` (ADR-0001
  /// story 4) — the same cascade [markDone] runs. Trash deliberately leaves
  /// Action rows alone; they persist exactly as the Outcome row does.
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
    String? actionText,
    Set<String>? personTagIds,
    String? userId,
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final tsIso = ts.toIso8601String();
    // Only the Next / Waiting For arms carry a next-action phrase, and only
    // when the caller passes one; those are the arms that write the Action row.
    // An absent [actionText] leaves the Action untouched.
    final touchesAction = (to == RoutingKind.nextAction ||
            to == RoutingKind.waitingFor) &&
        actionText != null;
    var actionTerminated = false;
    var logChanged = false;
    await attachedDatabase.capturing(() => transaction(() async {
      final captured = switch (to) {
        RoutingKind.nextAction || RoutingKind.waitingFor => <String, Object?>{
            'clarified': true,
            'intent': 'next',
            'done_at': null,
            'last_clarified_at': encodeInstant(ts),
            'updated_at': encodeInstant(ts),
          },
        RoutingKind.maybe => <String, Object?>{
            'clarified': true,
            'intent': 'maybe',
            'done_at': null,
            'last_clarified_at': encodeInstant(ts),
            'updated_at': encodeInstant(ts),
          },
        RoutingKind.done => <String, Object?>{
            'clarified': true,
            'done_at': tsIso,
            'last_clarified_at': encodeInstant(ts),
            'updated_at': encodeInstant(ts),
          },
        RoutingKind.trash => <String, Object?>{
            'clarified': true,
            'intent': 'trash',
            'last_clarified_at': encodeInstant(ts),
            'updated_at': encodeInstant(ts),
          },
      };
      final companion = switch (to) {
        RoutingKind.nextAction || RoutingKind.waitingFor => TodosCompanion(
            clarified: const Value(true),
            intent: const Value('next'),
            doneAt: const Value(null),
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
      _captureTodo(todoId, captured);

      if (touchesAction) {
        final normalised = _normaliseText(actionText);
        if (normalised == null) {
          // Blank supersedes the current Action, closing its open log (#476).
          final effect = await attachedDatabase.actionDao
              .applySupersedeCurrentAction(todoId, ts: ts);
          logChanged = logChanged || effect.logChanged;
        } else {
          await attachedDatabase.actionDao
              .applySetCurrentAction(todoId, normalised, ts: ts);
        }
      }

      if (to == RoutingKind.done) {
        // Achieving the Outcome closes the current Action (ADR-0001 story 4) —
        // the same cascade markDone runs, sharing one apply-variant.
        final effect = await attachedDatabase.actionDao
            .applyCompleteCurrentAction(todoId, ts: ts);
        actionTerminated = effect.changed;
        logChanged = logChanged || effect.logChanged;
      }

      if (personTagIds != null) {
        if (userId == null) {
          throw ArgumentError(
            'userId is required when personTagIds is provided',
          );
        }
        await setPersonTagsForTodo(todoId, personTagIds, userId);
      }
    }));

    // Notify explicitly so the Inbox / Next Actions lists refresh even when the
    // write touched a table they do not name — and so they do not depend solely
    // on the async update bridge, which was observed silent on the first cold
    // start of a new planning day (#342). Person-tag edits also touch
    // `todo_tags`, so refresh those watchers too.
    attachedDatabase.notifyTodosViewWrite(includeTodoTags: personTagIds != null);
    if (touchesAction || actionTerminated) {
      attachedDatabase.notifyActionsViewWrite();
    }
    // A supersede or completion in the cascade closes the current Action's open
    // TimeLog (#476); `time_logs` is a view too, so notify its watchers (ADR-0010).
    if (logChanged) attachedDatabase.notifyTimeLogsViewWrite();
  }

  static String? _normaliseText(String text) {
    final trimmed = text.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Update mutable todo fields (title, notes, energy level, time estimate, due date).
  ///
  /// Every field this method can change is a clarifying micro-act per
  /// CONTEXT.md (title / notes / due-date edits, and Action metadata energy /
  /// time-estimate — Actions are first-class per ADR-0001 and their mutations
  /// stamp). Any non-no-op call therefore stamps [lastClarifiedAt].
  ///
  /// **Energy / time-estimate are Action-grain metadata (ADR-0001 story 7).**
  /// This is the only live writer of them on an existing Outcome, so it writes
  /// both grains: the `todos.energy_level` / `time_estimate` columns stay
  /// mirrored (D1, and the draft store while the Outcome is Actionless per
  /// D3), and when a `current` Action exists the same values are written onto
  /// it through [ActionDao.applyEditAction] **in one transaction** with the
  /// same timestamp. The mirror is what keeps the per-field D2 COALESCE
  /// fallback ([effectiveEnergyLevelSql]) from resurfacing a retired Action's
  /// estimate, so both sides always reflect the edit.
  ///
  /// This metadata mirror is unrelated to the dropped `next_action_text`
  /// cursor (ADR-0022, ADR-0024) and deliberately outlives it.
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
    // Whether this call touches Action-grain metadata at all — the arm that
    // must be mirrored to the current Action.
    final touchesMetadata = energyLevel != null ||
        timeEstimate != null ||
        clearEnergyLevel ||
        clearTimeEstimate;
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
    final captured = <String, Object?>{
      'updated_at': encodeInstant(ts),
      if (hasMutation) 'last_clarified_at': encodeInstant(ts),
      'title': ?title,
      if (clearNotes) 'notes': null else 'notes': ?notes,
      if (clearEnergyLevel) 'energy_level': null else 'energy_level': ?energyLevel,
      if (clearTimeEstimate)
        'time_estimate': null
      else
        'time_estimate': ?timeEstimate,
      if (clearDueDate) 'due_date': null else 'due_date': ?encodeInstant(dueDate),
    };
    var actionTouched = false;
    await attachedDatabase.capturing(() => transaction(() async {
      await (update(todos)..where((t) => t.id.equals(todoId))).write(companion);
      _captureTodo(todoId, captured);
      if (touchesMetadata) {
        // Mirror onto the current Action, if one exists. Actionless
        // Outcomes keep the values as draft on the columns above (D3); the
        // draft seeds the birth Action when the next `current` Action is
        // created (ActionDao.applySetCurrentAction). Reading the current Action
        // on the transaction executor cannot race a synced write in mid-edit.
        final current =
            await attachedDatabase.actionDao.getCurrentAction(todoId);
        if (current != null) {
          final effect = await attachedDatabase.actionDao.applyEditAction(
            current.id,
            energyLevel: energyLevel,
            timeEstimate: timeEstimate,
            clearEnergyLevel: clearEnergyLevel,
            clearTimeEstimate: clearTimeEstimate,
            ts: ts,
          );
          actionTouched = effect.changed;
        }
      }
    }));
    attachedDatabase.notifyTodosViewWrite();
    if (actionTouched) attachedDatabase.notifyActionsViewWrite();
  }

  // ---------------------------------------------------------------------------
  // Outcome creation / deletion (Capture clarify — issue #184 Phase 2)
  // ---------------------------------------------------------------------------

  /// Inserts a new **clarified Outcome** row from a clarify-card draft.
  ///
  /// This is the create half of clarifying a Capture (ADR-0006): promoting a
  /// Capture produces a *new* Outcome rather than flipping the raw fragment in
  /// place. The row lands clarified (`clarified = true`) with `last_clarified_at`
  /// stamped — Outcome creation is a clarifying micro-act per CONTEXT.md — and a
  /// default `intent = 'next'`; the caller then refines intent / Completion via
  /// [applyRouting]. Person and non-person tag associations are attached
  /// out-of-band by the caller (the clarify service).
  ///
  /// [now] is injectable for deterministic testing.
  Future<void> insertOutcome({
    required String id,
    required String title,
    required String userId,
    String? notes,
    String? energyLevel,
    int? timeEstimate,
    DateTime? dueDate,
    String? captureSource,
    DateTime? now,
  }) async {
    // Normalise to UTC once and reuse for every timestamp column: a non-UTC
    // injected [now] must not land createdAt/updatedAt in local time while
    // lastClarifiedAt is UTC. UTC also keeps Drift's storeDateTimeAsText path
    // emitting the standard ISO-8601 spelling the op log's instant encoding
    // accepts (see rescheduleTask for the offset-string rationale).
    final ts = (now ?? DateTime.now()).toUtc();
    await attachedDatabase.capturing(() async {
      await into(todos).insert(TodosCompanion(
        id: Value(id),
        title: Value(title),
        notes: Value(notes),
        energyLevel: Value(energyLevel),
        timeEstimate: Value(timeEstimate),
        dueDate: dueDate != null ? Value(dueDate.toUtc()) : const Value.absent(),
        captureSource: Value(captureSource),
        userId: Value(userId),
        createdAt: Value(ts),
        updatedAt: Value(ts),
        clarified: const Value(true),
        lastClarifiedAt: Value(ts),
      ));
      // Creation asserts the whole row (minus the dead `time_spent_minutes`
      // cache) so a peer that has never seen this Outcome can build it.
      _captureTodo(id, {
        'title': title,
        'notes': notes,
        'priority': null,
        'due_date': encodeInstant(dueDate),
        'created_at': encodeInstant(ts),
        'updated_at': encodeInstant(ts),
        'done_at': null,
        'clarified': true,
        'intent': 'next',
        'time_estimate': timeEstimate,
        'energy_level': energyLevel,
        'capture_source': captureSource,
        'location_id': null,
        'user_id': userId,
        'last_clarified_at': encodeInstant(ts),
        'last_next_action_completion_at': null,
      });
      attachedDatabase.notifyTodosViewWrite();
    });
  }

  /// Hard-deletes an Outcome by [id]. Used by the Capture clarify flow to
  /// overwrite a session-created Outcome when the user re-routes a Capture
  /// (Ceremony Back → re-tap) or discards it — the Capture itself persists as
  /// provenance, only the just-carved Outcome is removed. Returns 1 if a row
  /// existed and was deleted, 0 if [id] was already gone.
  ///
  /// The affected-row count is derived from a pre-delete existence check rather
  /// than the delete's return value. Over the Drift-owned store `changes()`
  /// would in fact answer, but the check is also what tells the cascade what to
  /// enumerate on the op log, so deriving the count from it keeps one read
  /// instead of two answers that could disagree. Both run in one transaction so
  /// the count can't race the delete.
  /// The cascade set this delete enumerates on the op log, which is **wider
  /// than the local delete above**. The shipped path removes only the `actions`
  /// rows and the todo, leaving `todo_tags`, `capture_outcomes` and
  /// `time_logs.action_id` to the *server's* `ON DELETE CASCADE` / `SET NULL`
  /// on replication. The op log has no server cascade, so capture enumerates at
  /// authoring time exactly what the server used to do — and the projector then
  /// applies that widened set to the authoring device's own rows.
  ///
  /// TimeLogs are never destroyed: their `action_id` is nulled (SET NULL), and
  /// they keep Outcome-grain `task_id` attribution, rendering as *elsewhere*
  /// once the Outcome is gone.
  Future<void> _captureDeleteOutcomeCascade(String id) async {
    final capture = attachedDatabase.opCapture;
    final actionRows =
        await (select(actions)..where((a) => a.outcomeId.equals(id))).get();
    for (final row in actionRows) {
      capture.tombstone(collection: actionsCollection, entityId: row.id);
    }
    final junctionRows =
        await (select(todoTags)..where((tt) => tt.todoId.equals(id))).get();
    for (final row in junctionRows) {
      capture.tombstone(
        collection: todoTagsCollection,
        entityId: todoTagIdFor(row.todoId, row.tagId),
      );
    }
    final linkRows = await attachedDatabase.captureDao.captureIdsForOutcome(id);
    for (final captureId in linkRows) {
      capture.tombstone(
        collection: captureOutcomesCollection,
        entityId: captureOutcomeIdFor(captureId, id),
      );
    }
    final logRows = await (select(attachedDatabase.timeLogs)
          ..where((t) => t.taskId.equals(id) & t.actionId.isNotNull()))
        .get();
    for (final row in logRows) {
      capture.write(
        collection: timeLogsCollection,
        entityId: row.id,
        fields: {'action_id': null},
      );
    }
    capture.tombstone(collection: todosCollection, entityId: id);
  }

  Future<int> deleteOutcome(String id) async {
    return attachedDatabase.capturing(() => transaction(() async {
      final existed = await (select(todos)..where((t) => t.id.equals(id)))
              .getSingleOrNull() !=
          null;
      await _captureDeleteOutcomeCascade(id);
      // Cascade the Outcome's Action rows explicitly (ADR-0001 story 2): the op
      // log has no cascade of its own, so carve-undo must enumerate them to
      // leave no orphans on a peer that reduces this delete — mirroring the
      // `capture_outcomes` cascade convention. Deleted before the Outcome so
      // the delete never trips FK enforcement on the real-table test path. The
      // queued `DELETE /actions/{id}` uploads may 404 if the server's
      // `ON DELETE CASCADE` already removed the row; the connector's fatal-4xx
      // path skips those harmlessly (docs/SYNC.md).
      await (delete(actions)..where((a) => a.outcomeId.equals(id))).go();
      await (delete(todos)..where((t) => t.id.equals(id))).go();
      attachedDatabase.notifyTodosViewWrite();
      attachedDatabase.notifyActionsViewWrite();
      return existed ? 1 : 0;
    }));
  }
}
