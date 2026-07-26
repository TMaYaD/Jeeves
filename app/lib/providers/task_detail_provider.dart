import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:drift/drift.dart';

import '../database/daos/action_dao.dart' show TerminatedAction;
import '../database/daos/capture_dao.dart' show CarvedOutcome;
import '../database/gtd_database.dart';
import '../models/action_draft.dart';
import '../models/todo.dart' show Intent, RoutingKind;
import 'auth_provider.dart';
import 'database_provider.dart';

/// Watches a single todo by ID, re-emitting on any change.
final taskDetailTodoProvider =
    StreamProvider.autoDispose.family<Todo?, String>((ref, todoId) {
  final db = ref.watch(databaseProvider);
  return db.todoDao.watchTodo(todoId);
});

/// Watches the Outcome's current Action (or null when Actionless) — the anchor
/// of the Plan section (ADR-0004 story 5, issue #475).
final currentActionProvider =
    StreamProvider.autoDispose.family<Action?, String>((ref, outcomeId) {
  final db = ref.watch(databaseProvider);
  return db.actionDao.watchCurrentAction(outcomeId);
});

/// Watches the Outcome's ordered planned queue — the planned rows shown only in
/// the Outcome's detail view (never engageable; ADR-0004 story 5, issue #475).
final plannedActionsProvider =
    StreamProvider.autoDispose.family<List<Action>, String>((ref, outcomeId) {
  final db = ref.watch(databaseProvider);
  return db.actionDao.watchPlannedActions(outcomeId);
});

/// Watches the Outcome's history — its terminated Actions (`done` and
/// `superseded`) newest-first, each with the minutes logged against it
/// (ADR-0001 story 8, issue #478).
///
/// Empty for an Outcome that has never terminated an Action (including every
/// pre-epic Outcome backfilled by the `actions` migration); the detail screen
/// hides the history section entirely in that case.
final terminatedActionsProvider =
    StreamProvider.autoDispose.family<List<TerminatedAction>, String>(
  (ref, outcomeId) {
    final db = ref.watch(databaseProvider);
    return db.actionDao.watchTerminatedActions(outcomeId);
  },
);

/// Watches the Captures an Outcome was clarified from — its provenance
/// (`capture_outcomes`), newest link first (ADR-0006, issue #184 Phase 4).
///
/// Empty for Outcomes that predate the Capture split or were created outside
/// the clarify flow (they carry no links); the detail screen hides the
/// "Captured from…" section entirely in that case.
final capturesForOutcomeProvider =
    StreamProvider.autoDispose.family<List<Capture>, String>((ref, outcomeId) {
  final db = ref.watch(databaseProvider);
  return db.captureDao.watchCapturesForOutcome(outcomeId);
});

/// Watches a single Capture by ID — the clarify surfaces bind to this so an
/// edit (or hard-delete) synced from another device re-renders the open card.
final captureProvider =
    StreamProvider.autoDispose.family<Capture?, String>((ref, captureId) {
  final db = ref.watch(databaseProvider);
  return db.captureDao.watchCapture(captureId);
});

/// Watches the Outcomes a Capture claims, each with the number of Captures
/// claiming it — the n-m clarify surface's linked-Outcome list and the
/// provenance chip on a merged one.
///
/// The inverse of [capturesForOutcomeProvider], which reads the same links from
/// the Outcome's side for the task-detail "Captured from…" section.
final carvedOutcomesProvider =
    StreamProvider.autoDispose.family<List<CarvedOutcome>, String>(
  (ref, captureId) {
    final db = ref.watch(databaseProvider);
    return db.captureDao.watchCarvedOutcomes(captureId);
  },
);

/// Watches a Capture's tag *hints* (`capture_tags`) — the Capture-side
/// counterpart of [taskTagsProvider], feeding the clarify card's pickers.
///
/// Hints are not Organising (CONTEXT.md): they narrow the Inbox while the user
/// clears it and seed the Outcome's tags at clarification, but on their own
/// they place the Capture on no list.
final captureTagHintsProvider =
    StreamProvider.autoDispose.family<List<Tag>, String>((ref, captureId) {
  final db = ref.watch(databaseProvider);
  return db.captureDao.watchTagHints(captureId);
});

/// Watches the Drift Tag rows associated with [todoId], scoped to the current user.
final taskTagsProvider =
    StreamProvider.autoDispose.family<List<Tag>, String>((ref, todoId) {
  final db = ref.watch(databaseProvider);
  final userId = ref.watch(currentUserIdProvider);
  final query = db.select(db.tags).join([
    innerJoin(db.todoTags, db.todoTags.tagId.equalsExp(db.tags.id)),
    innerJoin(db.todos, db.todos.id.equalsExp(db.todoTags.todoId)),
  ])
    ..where(db.todoTags.todoId.equals(todoId) &
        db.todos.userId.equals(userId));
  return query.map((row) => row.readTable(db.tags)).watch();
});

/// Provides mutation operations for the task detail screen.
///
/// The notifier captures the [GtdDatabase] and current user id eagerly
/// rather than holding a [Ref].  `Provider.autoDispose` tears the ref
/// down between synchronous calls, so reading `databaseProvider` through
/// a stored [Ref] after an `await` throws "Cannot use the Ref … after it
/// has been disposed".  `GtdDatabase` is a process-wide singleton and
/// the screen pops on logout, so capturing both values at construction
/// is safe.
final taskDetailNotifierProvider =
    Provider.autoDispose.family<TaskDetailNotifier, String>((ref, todoId) {
  return TaskDetailNotifier(
    db: ref.read(databaseProvider),
    userId: ref.read(currentUserIdProvider),
    todoId: todoId,
  );
});

class TaskDetailNotifier {
  TaskDetailNotifier({
    required GtdDatabase db,
    required String userId,
    required String todoId,
  })  : _db = db,
        _userId = userId,
        _todoId = todoId;

  final GtdDatabase _db;
  final String _userId;
  final String _todoId;

  Future<void> updateTitle(String title) => _db.todoDao.updateFields(
        _todoId,
        title: title.trim(),
      );

  Future<void> updateNotes(String notes) => _db.todoDao.updateFields(
        _todoId,
        notes: notes,
      );

  Future<void> setEnergyLevel(String level) => _db.todoDao.updateFields(
        _todoId,
        energyLevel: level,
      );

  // Route clear-cursor writes through the DAO so last_clarified_at is stamped
  // consistently with every other Action mutation (ADR-0001 + CONTEXT.md L152).
  Future<void> clearEnergyLevel() => _db.todoDao.updateFields(
        _todoId,
        clearEnergyLevel: true,
      );

  Future<void> clearTimeEstimate() => _db.todoDao.updateFields(
        _todoId,
        clearTimeEstimate: true,
      );

  Future<void> setTimeEstimate(int minutes) => _db.todoDao.updateFields(
        _todoId,
        timeEstimate: minutes,
      );

  Future<void> setDueDate(DateTime date) => _db.todoDao.updateFields(
        _todoId,
        dueDate: date,
      );

  Future<void> clearDueDate() => _db.todoDao.updateFields(
        _todoId,
        clearDueDate: true,
      );

  Future<void> assignProject(String tagId) =>
      _db.tagDao.enforceSingleProject(_todoId, _userId, tagId);

  Future<void> clearProject() async {
    final todo = await _db.todoDao.getTodo(_todoId);
    if (todo == null) return;
    final projectTagIds = await (_db.select(_db.tags)
          ..where((t) => t.type.equals('project')))
        .map((t) => t.id)
        .get();
    if (projectTagIds.isEmpty) return;
    await (_db.delete(_db.todoTags)
          ..where(
            (jt) =>
                jt.todoId.equals(_todoId) & jt.tagId.isIn(projectTagIds),
          ))
        .go();
  }

  Future<void> assignContextTag(String tagId) async {
    await _db.tagDao.assignTag(_todoId, tagId, _userId);
  }

  Future<void> removeContextTag(String tagId) async {
    await (_db.delete(_db.todoTags)
          ..where(
            (jt) => jt.todoId.equals(_todoId) & jt.tagId.equals(tagId),
          ))
        .go();
  }

  /// Assigns a person-typed tag to this todo and stamps last_clarified_at.
  Future<void> assignPersonTag(String tagId) async {
    await _db.tagDao.assignTag(_todoId, tagId, _userId);
    await _db.todoDao.stampLastClarifiedAt(_todoId);
  }

  /// Removes a person-typed tag from this todo and stamps last_clarified_at.
  Future<void> removePersonTag(String tagId) async {
    await (_db.delete(_db.todoTags)
          ..where(
            (jt) => jt.todoId.equals(_todoId) & jt.tagId.equals(tagId),
          ))
        .go();
    await _db.todoDao.stampLastClarifiedAt(_todoId);
  }

  /// Replaces this todo's person-typed tags with exactly [tagIds] and stamps
  /// last_clarified_at. Both writes share one transaction, so a failure leaves
  /// the delegate set and the timestamp exactly as they were rather than
  /// half-applied — which a per-tag assign/remove loop cannot promise.
  /// Non-person tags are untouched.
  Future<void> setPersonTags(Set<String> tagIds) =>
      _db.todoDao.setPersonTagsAndStamp(_todoId, tagIds, _userId);

  /// Removes all person-typed tags from this todo and stamps last_clarified_at.
  Future<void> clearAllPersonTags() async {
    final personTagIds = await (_db.select(_db.tags)
          ..where((t) => t.type.equals('person')))
        .map((t) => t.id)
        .get();
    if (personTagIds.isEmpty) return;
    await (_db.delete(_db.todoTags)
          ..where(
            (jt) =>
                jt.todoId.equals(_todoId) & jt.tagId.isIn(personTagIds),
          ))
        .go();
    await _db.todoDao.stampLastClarifiedAt(_todoId);
  }

  // --- Planned queue (ADR-0004 story 5, issue #475) ---

  /// Append a `planned` Action to this Outcome's queue, exactly as [draft]
  /// describes it.
  ///
  /// Writes nothing to the Outcome's `energy_level` / `time_estimate` columns:
  /// a `planned` row is not engageable (ADR-0004), so its effort values must
  /// not reach the mirror D2's COALESCE reads as the *current* Action's. The
  /// mirror is re-established at promotion, by `ActionDao._promoteRow`.
  Future<void> addPlannedAction(ActionDraft draft) =>
      _db.actionDao.addPlannedAction(
        _todoId,
        draft.text,
        energyLevel: draft.energyLevel,
        timeEstimate: draft.timeEstimateMinutes,
      );

  /// **Replace** an Action's attributes with [draft] — not a patch.
  ///
  /// The sheet that produces the draft shows every field, so a null on it is
  /// the user having deselected a chip, not "leave alone". [ActionDao.editAction]
  /// reads a null typed argument as *no change*, so the nulls are mapped onto
  /// its `clear*` flags here; without that, deselecting a chip would silently
  /// fail to clear.
  ///
  /// The patch-shaped sibling is [TodoDao.updateFields], on the Outcome grain.
  /// The Plan section routes only `planned` rows here, but that is a division
  /// of labour rather than a safety requirement: `ActionDao.applyEditAction`
  /// mirrors onto the Outcome columns itself when the row it loads is
  /// `current`, so a row promoted between this sheet opening and its Save
  /// still leaves D1 intact (`docs/ARCHITECTURE.md`).
  Future<void> editAction(String actionId, ActionDraft draft) =>
      _db.actionDao.editAction(
        actionId,
        text: draft.text,
        energyLevel: draft.energyLevel,
        timeEstimate: draft.timeEstimateMinutes,
        clearEnergyLevel: draft.energyLevel == null,
        clearTimeEstimate: draft.timeEstimateMinutes == null,
      );

  /// Rewrite the planned queue order to [orderedIds].
  Future<void> reorderPlannedActions(List<String> orderedIds) =>
      _db.actionDao.reorderPlannedActions(_todoId, orderedIds);

  /// Promote a planned Action to current (throws if a current already exists —
  /// the UI routes that case through [supersedeAndPromote]).
  Future<void> promotePlannedAction(String actionId) =>
      _db.actionDao.promotePlannedAction(actionId);

  /// Replace the current Action with the planned [actionId] (retire-and-promote
  /// in one act).
  Future<void> supersedeAndPromote(String actionId) =>
      _db.actionDao.supersedeAndPromote(actionId);

  /// Demote the current Action [actionId] back to the front of the planned
  /// queue.
  Future<void> demoteCurrentAction(String actionId) =>
      _db.actionDao.demoteCurrentAction(actionId);

  /// Remove (hard-delete) a planned Action.
  Future<void> removePlannedAction(String actionId) =>
      _db.actionDao.removePlannedAction(actionId);

  /// **Abandon** the current Action: drop it into the Outcome's history with no
  /// replacement, leaving the Outcome Actionless (ADR-0001 story 8, #478).
  ///
  /// The copy↔model mapping, in one place: the user-facing verb is **Abandon**
  /// (past tense "Abandoned" on a history row), the model role is
  /// `superseded`, and the primitive is [ActionDao.clearCurrentAction] — a
  /// supersession with no successor, which ADR-0018 gives no linkage metadata,
  /// so its terminal timestamp is the row's `updated_at`.
  ///
  /// Distinct from **Remove**, which hard-deletes an unengaged `planned` row.
  /// Abandon retires; nothing is deleted and the row is never re-promotable.
  /// Unlike completion this *is* a clarifying act, so it stamps
  /// `last_clarified_at`. It writes nothing to `todos.next_action_text` — the
  /// cursor is retired (ADR-0022) — and needs no cursor clear to guard against
  /// resurrection: the startup sweep never reads the cursor at all.
  Future<void> abandonCurrentAction() =>
      _db.actionDao.clearCurrentAction(_todoId);

  Future<void> markDone() => _db.todoDao.markDone(_todoId);

  Future<void> setIntent(Intent intent) =>
      _db.todoDao.setIntent(_todoId, intent);

  /// Restores a done or trashed Outcome to the Intent named by [to]
  /// (`nextAction` or `maybe`) via [TodoDao.applyRouting]: sets the intent,
  /// clears `done_at` (cleanup invariant), and stamps `last_clarified_at`.
  /// Person tags survive (orthogonality invariant).
  Future<void> restoreTo(RoutingKind to) =>
      _db.todoDao.applyRouting(_todoId, to: to);

  /// Watch all tag associations for this todo (returns Drift [Tag] rows),
  /// scoped to the current user.
  Stream<List<Tag>> watchTags() {
    final query = _db.select(_db.tags).join([
      innerJoin(_db.todoTags, _db.todoTags.tagId.equalsExp(_db.tags.id)),
      innerJoin(_db.todos, _db.todos.id.equalsExp(_db.todoTags.todoId)),
    ])
      ..where(_db.todoTags.todoId.equals(_todoId) &
          _db.todos.userId.equals(_userId));
    return query.map((row) => row.readTable(_db.tags)).watch();
  }
}
