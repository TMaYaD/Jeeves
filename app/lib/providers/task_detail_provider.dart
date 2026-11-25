import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:drift/drift.dart';

import '../database/daos/action_dao.dart' show TerminatedAction;
import '../database/daos/capture_dao.dart' show CarvedOutcome;
import '../database/gtd_database.dart';
import '../models/action_draft.dart';
import '../models/place_area.dart';
import '../models/time_context.dart';
import '../models/intent.dart';
import '../models/routing_kind.dart';
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

  /// Runs [write] only if the Outcome is still in local storage, checked inside
  /// the write's own transaction. Returns whether it landed. Every write below
  /// goes through here — except the two Person-set writes, whose DAO method
  /// makes the same check inside the same transaction — so a surface that
  /// outlives its Outcome (a focus-loss save, a dispose flush, a sheet opened
  /// before the delete) cannot write to it (#447). Callers that do not care may
  /// ignore the result.
  Future<bool> _ifOutcomePresent(Future<void> Function() write) =>
      _db.todoDao.writeIfOutcomePresent(_todoId, write);

  Future<bool> updateTitle(String title) =>
      _ifOutcomePresent(() => _db.todoDao.updateFields(
        _todoId,
        title: title.trim(),
      ));

  /// Writes the notes, nulling the column when the field is emptied.
  ///
  /// `null` is "no change" to `TodoDao.updateFields`, so a clear has to travel
  /// as `clearNotes`: passing `notes: ''` stores `''`, and every
  /// `notes == null` read then treats that as "has notes" (#528, #705).
  ///
  /// Trims, like [updateTitle] and like the two surfaces that already honour
  /// the contract (`ActiveFocusScreen`, `ClarifyCard`), so whitespace-only
  /// notes are a clear rather than stored verbatim. All three Outcome-detail
  /// notes writers — the focus-loss listener, the markdown-checkbox write and
  /// the `dispose()` backstop — go through here, so they cannot disagree.
  Future<bool> updateNotes(String notes) {
    final trimmed = notes.trim();
    return _ifOutcomePresent(() => _db.todoDao.updateFields(
          _todoId,
          notes: trimmed.isNotEmpty ? trimmed : null,
          clearNotes: trimmed.isEmpty,
        ));
  }

  /// Title and notes in one write (the ClarifyCard save and its dispose
  /// flush). Both arguments are already trimmed; an emptied notes field nulls
  /// the column rather than storing `''` (see [updateNotes]).
  Future<bool> updateTitleAndNotes(String title, String notes) =>
      _ifOutcomePresent(() => _db.todoDao.updateFields(
            _todoId,
            title: title,
            notes: notes.isNotEmpty ? notes : null,
            clearNotes: notes.isEmpty,
          ));

  /// Sets the energy level, or clears it when [level] is null.
  Future<bool> updateEnergyLevel(String? level) =>
      _ifOutcomePresent(() => _db.todoDao.updateFields(
            _todoId,
            energyLevel: level,
            clearEnergyLevel: level == null,
          ));

  /// Sets the time estimate, or clears it when [minutes] is null.
  Future<bool> updateTimeEstimate(int? minutes) =>
      _ifOutcomePresent(() => _db.todoDao.updateFields(
            _todoId,
            timeEstimate: minutes,
            clearTimeEstimate: minutes == null,
          ));

  /// Sets the due date, or clears it when [clear] is true.
  Future<bool> updateDueDate(DateTime? date, {required bool clear}) =>
      _ifOutcomePresent(() => _db.todoDao.updateFields(
            _todoId,
            dueDate: date,
            clearDueDate: clear,
          ));

  Future<bool> setEnergyLevel(String level) =>
      _ifOutcomePresent(() => _db.todoDao.updateFields(
        _todoId,
        energyLevel: level,
      ));

  // Route clear-cursor writes through the DAO so last_clarified_at is stamped
  // consistently with every other Action mutation (ADR-0001 + CONTEXT.md L152).
  Future<bool> clearEnergyLevel() =>
      _ifOutcomePresent(() => _db.todoDao.updateFields(
        _todoId,
        clearEnergyLevel: true,
      ));

  Future<bool> clearTimeEstimate() =>
      _ifOutcomePresent(() => _db.todoDao.updateFields(
        _todoId,
        clearTimeEstimate: true,
      ));

  Future<bool> setTimeEstimate(int minutes) =>
      _ifOutcomePresent(() => _db.todoDao.updateFields(
        _todoId,
        timeEstimate: minutes,
      ));

  /// Sets or clears (null) the TimeContext of the Action [actionId] the editor
  /// was opened for. Returns whether the Outcome was still present. The write
  /// is dropped when that Action is no longer the Outcome's current one (it
  /// was replaced or abandoned while the sheet was open, e.g. by a sync), so
  /// an edit never lands on a successor the user did not see. Does not stamp
  /// `last_clarified_at` (Organising).
  Future<bool> setTimeContext(TimeContext? value,
      {required String actionId}) async {
    var wrote = false;
    final present = await _ifOutcomePresent(() async {
      final current = await _db.actionDao.getCurrentAction(_todoId);
      if (current == null || current.id != actionId) return;
      wrote = await _db.actionDao.applySetTimeContext(
        current.id,
        value,
        ts: DateTime.now().toUtc(),
      );
    });
    if (wrote) {
      _db.notifyActionsViewWrite();
      _db.notifyTodosViewWrite();
    }
    return present;
  }

  /// Sets or clears (null) the named time window of the Action [actionId] the
  /// editor was opened for. Returns whether the Outcome was still present.
  ///
  /// The write is dropped when that Action is no longer the Outcome's current
  /// one, exactly as [setTimeContext] drops its own: an edit never lands on a
  /// successor the user did not see. A named window and a Time context are
  /// exclusive — the write clears the other (issue #239).
  Future<bool> setTimeWindow(String? windowId,
      {required String actionId}) async {
    var wrote = false;
    final present = await _ifOutcomePresent(() async {
      final current = await _db.actionDao.getCurrentAction(_todoId);
      if (current == null || current.id != actionId) return;
      wrote = await _db.actionDao.applySetTimeWindow(
        current.id,
        windowId,
        ts: DateTime.now().toUtc(),
      );
    });
    if (wrote) {
      _db.notifyActionsViewWrite();
      _db.notifyTodosViewWrite();
    }
    return present;
  }

  /// Clears every kind of time on the Action [actionId] the editor was opened
  /// for: the named window and the one-time Time context, in one write.
  ///
  /// The write is dropped when that Action is no longer the Outcome's current
  /// one, exactly as [setTimeContext] and [setTimeWindow] drop theirs: an
  /// edit never lands on a successor the user did not see.
  Future<bool> clearTime({required String actionId}) async {
    var wrote = false;
    final present = await _ifOutcomePresent(() async {
      final current = await _db.actionDao.getCurrentAction(_todoId);
      if (current == null || current.id != actionId) return;
      wrote = await _db.actionDao.applyClearTime(
        current.id,
        ts: DateTime.now().toUtc(),
      );
    });
    if (wrote) {
      _db.notifyActionsViewWrite();
      _db.notifyTodosViewWrite();
    }
    return present;
  }

  /// Sets the estimate and the Timeboxed switch of the Action the sheet was
  /// opened for, in one write (issue #923).
  ///
  /// The estimate sheet offers the two together, so they are written together:
  /// one transaction, one timestamp, and the estimate and the switch can never
  /// disagree about which Action they belong to.
  ///
  /// [minutes] is the new estimate; null leaves it alone unless [clearEstimate]
  /// says to clear it. [timeboxed] is the new switch; null leaves it alone.
  ///
  /// [estimateIfUnset] is the estimate the sheet shows. It is written only
  /// when the switch is turned on and the Action carries no estimate of its
  /// own: a limit is measured against the Action's estimate, so a switch with
  /// none is not a limit. The Action's own estimate is read here, inside the
  /// write, so a peer that cleared it while the sheet was open cannot leave a
  /// switch with nothing to limit — the estimate the sheet shows travels with
  /// the switch instead.
  ///
  /// The switch lives on the Action, not the Outcome, so it is written with the
  /// same guard [setTimeContext] uses: it is dropped when that Action is no
  /// longer the Outcome's current one, so an edit never lands on a successor
  /// the user did not see. The estimate is an Outcome's own, so it goes
  /// whichever Action is current.
  Future<bool> setEstimateAndTimeboxed({
    required String actionId,
    int? minutes,
    bool clearEstimate = false,
    bool? timeboxed,
    int? estimateIfUnset,
  }) async {
    return _ifOutcomePresent(() async {
      final current = await _db.actionDao.getCurrentAction(_todoId);
      // The switch belongs to the Action the sheet was opened for: when that
      // Action is no longer the current one, the switch is not written.
      final action = current != null && current.id == actionId ? current : null;
      final needsEstimate = action != null &&
          timeboxed == true &&
          !clearEstimate &&
          action.timeEstimate == null &&
          estimateIfUnset != null;
      await _db.todoDao.updateFields(
        _todoId,
        timeEstimate: minutes ?? (needsEstimate ? estimateIfUnset : null),
        clearTimeEstimate: clearEstimate,
        timeboxed: action != null ? timeboxed : null,
      );
    });
  }

  /// Sets the named Place of the Action the sheet was opened for (issue #55).
  ///
  /// Guarded like [setTimeContext]: the write is dropped when that Action is
  /// no longer the Outcome's current one, so an edit never lands on a
  /// successor the user did not see.
  ///
  /// A one-time pin the Action stops pointing at goes with the reference; a
  /// named Place belongs to the user's list and stays in it.
  /// Sets the named Place on the Action the sheet was opened for (issue #55).
  ///
  /// Returns whether the Place was written: a write that the guard drops —
  /// the Action that was current when the sheet opened is no longer current —
  /// writes nothing and says so.
  Future<bool> setNamedPlace({
    required String actionId,
    required String placeId,
  }) async {
    var written = false;
    final outcomePresent = await _ifOutcomePresent(() async {
      final current = await _db.actionDao.getCurrentAction(_todoId);
      if (current == null || current.id != actionId) return;
      written = await _db.actionDao.setNamedPlace(current.id, placeId);
    });
    return outcomePresent && written;
  }

  /// Drops a one-time pin on the Action the sheet was opened for (issue #55).
  ///
  /// A pin belongs to this one Action: it is never listed anywhere, and it goes
  /// when the Action stops pointing at it. The same guard as [setNamedPlace]
  /// applies, and the answer says whether the pin was actually dropped.
  Future<bool> setPin({
    required String actionId,
    required PlaceArea area,
    String? name,
  }) async {
    var written = false;
    final outcomePresent = await _ifOutcomePresent(() async {
      final current = await _db.actionDao.getCurrentAction(_todoId);
      if (current == null || current.id != actionId) return;
      final pinId = await _db.actionDao.setPin(current.id, area, name: name);
      written = pinId != null;
    });
    return outcomePresent && written;
  }

  /// Clears the Place of the Action the sheet was opened for (issue #55).
  Future<bool> clearPlace({required String actionId}) async {
    var written = false;
    final outcomePresent = await _ifOutcomePresent(() async {
      final current = await _db.actionDao.getCurrentAction(_todoId);
      if (current == null || current.id != actionId) return;
      written = await _db.actionDao.setNamedPlace(current.id, null);
    });
    return outcomePresent && written;
  }

  Future<bool> setDueDate(DateTime date) =>
      _ifOutcomePresent(() => _db.todoDao.updateFields(
        _todoId,
        dueDate: date,
      ));

  Future<bool> clearDueDate() =>
      _ifOutcomePresent(() => _db.todoDao.updateFields(
        _todoId,
        clearDueDate: true,
      ));

  Future<bool> assignProject(String tagId) =>
      _ifOutcomePresent(
          () => _db.tagDao.enforceSingleProject(_todoId, _userId, tagId));

  /// Clears this Outcome's Project link, leaving the Project Tag itself.
  ///
  /// The link and the tombstone a peer needs to drop it too are written in one
  /// transaction, so the removal reaches the sync host instead of living on
  /// this device until the next pull restores the Project.
  Future<bool> clearProject() =>
      _ifOutcomePresent(() => _db.tagDao.removeProjectFromTodo(_todoId));

  Future<bool> assignContextTag(String tagId) =>
      _ifOutcomePresent(() async {
      await _db.tagDao.assignTag(_todoId, tagId, _userId);
      });

  /// Removes a context-typed tag from this Outcome.
  ///
  /// The link and its tombstone share one transaction: unassignment is a
  /// tombstone op, never row absence, or a replayed assignment would
  /// re-attach the tag on the peer.
  Future<bool> removeContextTag(String tagId) =>
      _ifOutcomePresent(() => _db.tagDao.unassignTag(_todoId, tagId));

  /// Assigns a person-typed tag to this todo and stamps last_clarified_at.
  Future<bool> assignPersonTag(String tagId) =>
      _ifOutcomePresent(() async {
      await _db.tagDao.assignTag(_todoId, tagId, _userId);
      await _db.todoDao.stampLastClarifiedAt(_todoId);
      });

  /// Removes a person-typed tag from this todo and stamps last_clarified_at.
  ///
  /// The link, its tombstone and the stamp share one transaction, so the
  /// removal reaches the peer and the Outcome's clarification moment agrees
  /// with the delegate set the peer ends up with.
  Future<bool> removePersonTag(String tagId) =>
      _ifOutcomePresent(() async {
      await _db.tagDao.unassignTag(_todoId, tagId);
      await _db.todoDao.stampLastClarifiedAt(_todoId);
      });

  /// Replaces this todo's person-typed tags with exactly [tagIds] and stamps
  /// last_clarified_at. Both writes share one transaction, so a failure leaves
  /// the delegate set and the timestamp exactly as they were rather than
  /// half-applied — which a per-tag assign/remove loop cannot promise.
  /// Non-person tags are untouched. Returns `false` when the Outcome is gone
  /// from local storage and nothing was written.
  Future<bool> setPersonTags(Set<String> tagIds) =>
      _db.todoDao.setPersonTagsAndStamp(_todoId, tagIds, _userId);

  /// Removes all person-typed tags from this todo and stamps last_clarified_at.
  ///
  /// An empty target set is the whole delegate set, so this reuses the same
  /// path the Person picker uses: every link it drops is tombstoned in the
  /// same transaction as the stamp, and the peer ends up with no delegates
  /// rather than with the ones this device still had.
  Future<bool> clearAllPersonTags() =>
      _db.todoDao.setPersonTagsAndStamp(_todoId, const <String>{}, _userId);

  // --- Planned queue (ADR-0004 story 5, issue #475) ---

  /// Append a `planned` Action to this Outcome's queue, exactly as [draft]
  /// describes it.
  ///
  /// Writes nothing to the Outcome's `energy_level` / `time_estimate` columns:
  /// a `planned` row is not engageable (ADR-0004), so its effort values must
  /// not reach the mirror D2's COALESCE reads as the *current* Action's. The
  /// mirror is re-established at promotion, by `ActionDao._promoteRow`.
  Future<bool> addPlannedAction(ActionDraft draft) =>
      _ifOutcomePresent(() => _db.actionDao.addPlannedAction(
        _todoId,
        draft.text,
        energyLevel: draft.energyLevel,
        timeEstimate: draft.timeEstimateMinutes,
      ));

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
  Future<bool> editAction(String actionId, ActionDraft draft) =>
      _ifOutcomePresent(() => _db.actionDao.editAction(
        actionId,
        text: draft.text,
        energyLevel: draft.energyLevel,
        timeEstimate: draft.timeEstimateMinutes,
        clearEnergyLevel: draft.energyLevel == null,
        clearTimeEstimate: draft.timeEstimateMinutes == null,
      ));

  /// Rewrite the planned queue order to [orderedIds].
  Future<bool> reorderPlannedActions(List<String> orderedIds) =>
      _ifOutcomePresent(
          () => _db.actionDao.reorderPlannedActions(_todoId, orderedIds));

  /// Promote a planned Action to current (throws if a current already exists —
  /// the UI routes that case through [supersedeAndPromote]).
  Future<bool> promotePlannedAction(String actionId) =>
      _ifOutcomePresent(() => _db.actionDao.promotePlannedAction(actionId));

  /// Replace the current Action with the planned [actionId] (retire-and-promote
  /// in one act). [expectedCurrentActionId] is the current Action the replace
  /// confirm showed the user; the write throws rather than retire a different
  /// one if the current changed under the open sheet (#723).
  Future<bool> supersedeAndPromote(
    String actionId, {
    String? expectedCurrentActionId,
  }) =>
      _ifOutcomePresent(() => _db.actionDao.supersedeAndPromote(
        actionId,
        expectedCurrentActionId: expectedCurrentActionId,
      ));

  /// Demote the current Action [actionId] back to the front of the planned
  /// queue.
  Future<bool> demoteCurrentAction(String actionId) =>
      _ifOutcomePresent(() => _db.actionDao.demoteCurrentAction(actionId));

  /// Remove (hard-delete) a planned Action.
  Future<bool> removePlannedAction(String actionId) =>
      _ifOutcomePresent(() => _db.actionDao.removePlannedAction(actionId));

  /// **Abandon** the current Action: drop it into the Outcome's history with no
  /// replacement, leaving the Outcome Actionless (ADR-0001 story 8, #478).
  ///
  /// The copy↔model mapping, in one place: the user-facing verb is **Abandon**
  /// (past tense "Abandoned" on a history row), the model role is
  /// `superseded`, and the primitive is [ActionDao.clearCurrentAction] — a
  /// supersession with no successor, which carries no linkage metadata,
  /// so its terminal timestamp is the row's `updated_at`.
  ///
  /// Distinct from **Remove**, which hard-deletes an unengaged `planned` row.
  /// Abandon retires; nothing is deleted and the row is never re-promotable.
  /// Unlike completion this *is* a clarifying act, so it stamps
  /// `last_clarified_at`. It writes only `actions` and needs no cursor clear to
  /// guard against resurrection: the `todos.next_action_text` column is gone
  /// and the startup sweep reads no Outcome column at all.
  Future<bool> abandonCurrentAction() =>
      _ifOutcomePresent(() => _db.actionDao.clearCurrentAction(_todoId));

  Future<bool> markDone() =>
      _ifOutcomePresent(() => _db.todoDao.markDone(_todoId));

  Future<bool> setIntent(Intent intent) =>
      _ifOutcomePresent(() => _db.todoDao.setIntent(_todoId, intent));

  /// Restores a done or trashed Outcome to the Intent named by [to]
  /// (`nextAction` or `maybe`) via [TodoDao.applyRouting]: sets the intent,
  /// clears `done_at` (cleanup invariant), and stamps `last_clarified_at`.
  /// Person tags survive (orthogonality invariant).
  Future<bool> restoreTo(RoutingKind to) =>
      _ifOutcomePresent(() => _db.todoDao.applyRouting(_todoId, to: to));

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
