/// DAO owning the Action lifecycle primitives (ADR-0001 story 2, issue #472).
///
/// An [Action] is a first-class entity against an Outcome (`todos`); this DAO
/// is the single writer of the `actions` table in-app. Every *public* mutating
/// primitive:
///
/// * runs inside a transaction so a partial write can never land,
/// * stamps `Outcome.last_clarified_at` once, through [_stampOutcome] — the
///   stamping rule (CONTEXT.md § Clarification: every Action mutation is a
///   clarifying micro-act) is encoded here and nowhere else, and
/// * self-notifies after commit (ADR-0010): in production `actions` is a
///   PowerSync view with INSTEAD OF triggers, so a Drift write reports
///   `changes() == 0` and Drift's stream invalidation never fires — the write
///   path must call [GtdDatabase.notifyActionsViewWrite] itself, plus
///   [GtdDatabase.notifyTodosViewWrite] when it touched `todos`.
///
/// **The one exception to the stamping rule is [completeCurrentAction]**
/// (ADR-0001 story 4): finishing the current Action is an *engagement* signal,
/// not a clarifying act (CONTEXT.md § Clarification), so it must leave
/// `last_clarified_at` where it is — that is exactly what makes the Outcome owe
/// a re-clarification the moment its Action is done. It still writes `todos`
/// (the cursor clear), so its `todos` notification is unconditional rather than
/// gated on `stamped`.
///
/// Per **ADR-0018** supersession carries no linkage metadata: a superseded
/// row's terminal timestamp is its `updated_at`, there is no `superseded_by_id`
/// / `superseded_at`. A text edit of an Action is an *in-place* edit of the
/// same row (a refinement of the same Action); supersession is an explicit
/// affordance that flips `role`. It is now UI-reachable through
/// [supersedeAndPromote] — the "Replace current action" gesture of the planned
/// queue (ADR-0004 story 5) — so it is no longer test-only.
///
/// **The planned queue (ADR-0004 story 5, issue #475).** Beyond the 0..1
/// `current` Action, an Outcome carries an ordered list of `planned` Actions —
/// externalised "what's next" thinking that is *not* engageable (it never
/// surfaces on Next / Focus / Today's Plan; every current-Action read filters
/// `role='current'`, so planned rows cannot leak). Ordering is a dense
/// `position` 0..n-1 per Outcome; reads tie-break `position, created_at, id` so
/// a cross-device duplicate/gap still renders deterministically, and the next
/// planned-queue write re-densifies. The primitives are [addPlannedAction] /
/// [reorderPlannedActions] / [promotePlannedAction] / [supersedeAndPromote] /
/// [demoteCurrentAction] / [removePlannedAction]; each stamps
/// `last_clarified_at` (CONTEXT.md § Clarification lists promote / demote /
/// reorder / remove among the stamping micro-acts), except a no-op reorder
/// (unchanged order writes nothing and does not stamp).
///
/// **Cursor dual-write on promotion/demotion is mandatory, not defensive**
/// (until story 9 retires `next_action_text`). The startup sweep
/// (`reconcileActionsWithCursorSteps`) treats the cursor as authoritative:
/// * a **promote** MUST set `todos.next_action_text` to the promoted text and
///   mirror the promoted row's `energy_level` / `time_estimate` onto the cursor
///   in the same transaction — else Pass B retires the new current as a phantom
///   at next launch, and Pass A mode-1 would clobber the Action's metadata back
///   from the stale cursor;
/// * a **demote** MUST clear `todos.next_action_text` — else Pass A mode-3
///   resurrects the demoted text as a fresh deterministic current row.
///
/// The dual-write choke points in [TodoDao] compose the current-Action
/// primitives through the `apply*` transaction-body variants (package-internal),
/// which run inside the caller's transaction and defer notification to the
/// caller (so watchers never re-read pre-commit state) — see
/// `TodoDao.setNextActionText` / `setNextActionTextIfActionless` /
/// `applyRouting` / `deleteOutcome`.
library;

import 'package:drift/drift.dart';
import 'package:powersync/powersync.dart' show uuid;

import '../gtd_database.dart';

part 'action_dao.g.dart';

/// The effect of an Action apply-step, so a caller can notify precisely after
/// its own transaction commits: [changed] iff any `actions` row was written,
/// [stamped] iff `last_clarified_at` was moved on the Outcome.
typedef ActionWriteEffect = ({bool changed, bool stamped});

const ActionWriteEffect _noEffect = (changed: false, stamped: false);

@DriftAccessor(tables: [Actions, Todos])
class ActionDao extends DatabaseAccessor<GtdDatabase> with _$ActionDaoMixin {
  ActionDao(super.db);

  // ---------------------------------------------------------------------------
  // Public primitives — each opens a transaction and notifies after commit.
  // ---------------------------------------------------------------------------

  /// Compatibility-shaped entry point the legacy one-field surfaces drive:
  /// create the Outcome's `current` Action if none exists, otherwise **edit it
  /// in place** (same row, same identity — a text edit is a refinement, never a
  /// supersession; ADR-0018). Identical text with no differing metadata is a
  /// no-op (no write, no stamp, no notify).
  ///
  /// Blank [text] is a caller error here — the dual-write shims route a blank
  /// write through [clearCurrentAction] instead.
  Future<void> setCurrentAction(
    String outcomeId,
    String text, {
    String? energyLevel,
    int? timeEstimate,
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await transaction(
      () => applySetCurrentAction(
        outcomeId,
        text,
        energyLevel: energyLevel,
        timeEstimate: timeEstimate,
        ts: ts,
      ),
    );
    _notify(effect);
  }

  /// In-place field edit of an Action by its id — role-agnostic, so it edits a
  /// `current` row (story 7 metadata) or a `planned` row (the planned queue's
  /// inline edit, story 5) with the same UPDATE [setCurrentAction] uses for
  /// text. No-op if the row is gone or nothing differs.
  ///
  /// A `null` typed argument is "no change"; pass the matching `clear*` flag to
  /// null a nullable metadata column (same convention as [TodoDao.updateFields],
  /// which drives this in the same transaction for the metadata dual-write).
  Future<void> editAction(
    String actionId, {
    String? text,
    String? energyLevel,
    int? timeEstimate,
    bool clearEnergyLevel = false,
    bool clearTimeEstimate = false,
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await transaction(
      () => applyEditAction(
        actionId,
        text: text,
        energyLevel: energyLevel,
        timeEstimate: timeEstimate,
        clearEnergyLevel: clearEnergyLevel,
        clearTimeEstimate: clearTimeEstimate,
        ts: ts,
      ),
    );
    _notify(effect);
  }

  /// The explicit-affordance primitive (ADR-0018): flip the Outcome's current
  /// Action to `role='superseded'` (no linkage columns — the terminal time is
  /// `updated_at`), then, if [newActionText] is non-blank, mint a fresh
  /// `current` row. Its retire-then-mint transaction is the shape supersession
  /// takes everywhere; the planned queue's "Replace current action" gesture
  /// reaches supersession through the sibling [supersedeAndPromote] (which
  /// retires the current and flips an existing planned row up), while this
  /// text-taking variant backs [clearCurrentAction] and the re-clarify-to-new
  /// path (story 8).
  Future<void> supersedeCurrentAction(
    String outcomeId, {
    String? newActionText,
    String? newEnergyLevel,
    int? newTimeEstimate,
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await transaction(
      () => applySupersedeCurrentAction(
        outcomeId,
        newActionText: newActionText,
        newEnergyLevel: newEnergyLevel,
        newTimeEstimate: newTimeEstimate,
        ts: ts,
      ),
    );
    _notify(effect);
  }

  /// Make the Outcome Actionless: [supersedeCurrentAction] with no replacement.
  /// No current row → no-op (no stamp). This is the Action side of today's
  /// `setNextActionText('')` blank→NULL normalisation.
  Future<void> clearCurrentAction(String outcomeId, {DateTime? now}) =>
      supersedeCurrentAction(outcomeId, now: now);

  /// Record the current Action as **done** (ADR-0001 story 4): flip it to
  /// `role='done'` with `done_at`, and leave the Outcome in the no-current-
  /// Action state (ADR-0004 — nothing is auto-promoted; the user re-clarifies).
  ///
  /// Deliberately does **not** stamp `Outcome.last_clarified_at`: completion is
  /// the engagement signal, not clarification, so the Outcome immediately
  /// satisfies the re-clarify predicate. It does clear
  /// `todos.next_action_text` in the same transaction — mandatory, not
  /// defensive, because the startup sweep reads a non-blank cursor with no
  /// current row as drift and would mint a fresh `current` Action, resurrecting
  /// the Action the user just finished.
  ///
  /// No-op on an Actionless Outcome, and idempotent: a replay finds no current
  /// row and writes nothing, so a completion can never produce two terminal
  /// rows or push the completion timestamp forward.
  Future<void> completeCurrentAction(String outcomeId, {DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await transaction(
      () => applyCompleteCurrentAction(outcomeId, ts: ts),
    );
    if (effect.changed) {
      attachedDatabase.notifyActionsViewWrite();
      // The cursor clear writes `todos` without stamping, so this notification
      // cannot ride on [ActionWriteEffect.stamped] — which is always false here.
      attachedDatabase.notifyTodosViewWrite();
    }
  }

  // ---------------------------------------------------------------------------
  // Planned-queue primitives (ADR-0004 story 5, issue #475). Each opens a
  // transaction, stamps, and notifies after commit.
  // ---------------------------------------------------------------------------

  /// Append (or insert at [position]) a `planned` Action on the Outcome. Blank
  /// [text] is a caller error (mirrors [setCurrentAction]). With no [position]
  /// the row lands after the last planned row; an explicit [position] inserts
  /// there and shifts the rest down. Stamps.
  Future<void> addPlannedAction(
    String outcomeId,
    String text, {
    String? energyLevel,
    int? timeEstimate,
    int? position,
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await transaction(
      () => applyAddPlannedAction(
        outcomeId,
        text,
        energyLevel: energyLevel,
        timeEstimate: timeEstimate,
        position: position,
        ts: ts,
      ),
    );
    _notify(effect);
  }

  /// Rewrite the Outcome's planned queue to dense positions `0..n-1` in
  /// [orderedIds] order. Drift-tolerant: ids not among the Outcome's planned
  /// rows are ignored, and any planned row missing from [orderedIds] is appended
  /// keeping its prior relative order (a row synced mid-drag is never lost).
  /// A no-op — the effective order is already what the store holds — writes
  /// nothing and does not stamp; otherwise stamps once for the whole gesture.
  Future<void> reorderPlannedActions(
    String outcomeId,
    List<String> orderedIds, {
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await transaction(
      () => applyReorderPlannedActions(outcomeId, orderedIds, ts: ts),
    );
    _notify(effect);
  }

  /// Promote a `planned` Action to `current`. Refuses (`StateError`) when the
  /// Outcome already has a current Action — the caller must use
  /// [supersedeAndPromote] for the replacing variant, so no code path silently
  /// replaces a current (ADR-0004). No-op if the row is gone, is not `planned`,
  /// or is already `current` (idempotent under double-tap / replay). Sets the
  /// cursor per the promote dual-write rule and stamps.
  Future<void> promotePlannedAction(String actionId, {DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await transaction(
      () => applyPromotePlannedAction(actionId, ts: ts),
    );
    _notify(effect);
  }

  /// The "Replace current action" gesture: in one transaction retire the
  /// Outcome's current Action (`role='superseded'`, ADR-0018 — terminal time is
  /// `updated_at`, no linkage) and flip the `planned` [actionId] up to
  /// `current`, writing the cursor per the promote dual-write rule. No-op if the
  /// row is gone, already `current`, or not `planned`. Stamps once.
  Future<void> supersedeAndPromote(String actionId, {DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await transaction(
      () => applySupersedeAndPromote(actionId, ts: ts),
    );
    _notify(effect);
  }

  /// Demote the current Action [actionId] back into the planned queue at
  /// [position] (default 0 — front of the queue, the just-committed thought
  /// stays the most-likely next candidate), shifting the existing planned rows
  /// down. Clears the cursor text per the demote dual-write rule. No-op if the
  /// row is gone or is not `current`. Stamps.
  Future<void> demoteCurrentAction(
    String actionId, {
    int? position,
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await transaction(
      () => applyDemoteCurrentAction(actionId, position: position, ts: ts),
    );
    _notify(effect);
  }

  /// Hard-delete a `planned` Action (user-intent removal of an unengaged note —
  /// a planned row carries no engagement or history worth a `superseded`
  /// tombstone, ADR-0004 story 5). No-op — and never a delete — if the row is
  /// gone or is not `planned`. Stamps.
  Future<void> removePlannedAction(String actionId, {DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await transaction(
      () => applyRemovePlannedAction(actionId, ts: ts),
    );
    _notify(effect);
  }

  void _notify(ActionWriteEffect effect) {
    if (effect.changed) attachedDatabase.notifyActionsViewWrite();
    if (effect.stamped) attachedDatabase.notifyTodosViewWrite();
  }

  // ---------------------------------------------------------------------------
  // Reads (ADR-0001 story 3, issue #473) — the current Action *is* the answer
  // to "what is this Outcome's next move?".
  //
  // Every method below is a pure SELECT: it never opens a transaction, never
  // stamps `last_clarified_at`, never converges a multi-current set and never
  // notifies. Repair belongs to the writers (which converge as they go) and to
  // the startup sweep; a read that repaired would turn rendering a list into a
  // sync-visible write. Where a multi-current race is visible, reads apply the
  // same winner rule the writers use ([_winnerFirst]) so every surface — and
  // every device — displays the same row.
  // ---------------------------------------------------------------------------

  /// SQL ordering fragment that puts the winning `current` row first, for
  /// subselects in other DAOs' list queries (e.g. `CaptureDao`). Mirrors
  /// [_winnerFirst]; the Dart comparator stays the canonical rule.
  static const winnerFirstOrderSql =
      'ORDER BY COALESCE(actions.updated_at, actions.created_at) DESC, '
      'actions.id ASC';

  /// Correlated subquery: the winning `current` Action's [column] for the
  /// Outcome referenced by [outcomeIdRef] (a SQL expression, e.g. `'todos.id'`
  /// or `'t.id'`), or NULL when the Outcome is Actionless. Applies the same
  /// winner rule reads use ([_winnerFirst]) so a multi-current race resolves
  /// deterministically. The inner alias `mca` avoids colliding with outer
  /// table aliases.
  ///
  /// This is the single derivation of an Action-grain metadata value from the
  /// `actions` table (ADR-0001 story 7); the effective-read COALESCE that wraps
  /// it — current Action's value, else the Outcome column fallback — lives in
  /// [TodoDao.effectiveEnergyLevelSql] / [TodoDao.effectiveTimeEstimateSql],
  /// mirroring the `TimeLogDao.totalMinutesSubquery` precedent (issue #480).
  static String currentActionColumnSubquery(
    String column,
    String outcomeIdRef,
  ) =>
      '(SELECT mca.$column FROM actions mca '
      "WHERE mca.outcome_id = $outcomeIdRef AND mca.role = 'current' "
      'ORDER BY COALESCE(mca.updated_at, mca.created_at) DESC, mca.id ASC '
      'LIMIT 1)';

  /// The Outcome's current Action, or null when it is Actionless.
  Future<Action?> getCurrentAction(String outcomeId) async =>
      _pickWinner(await _currentActionsFor(outcomeId));

  /// Live view of the Outcome's current Action. Re-emits on any `actions`
  /// write — including one the sync bridge lands from another device, which
  /// arrives via [GtdDatabase.notifyActionsViewWrite] (ADR-0010).
  Stream<Action?> watchCurrentAction(String outcomeId) {
    return (select(actions)
          ..where((a) =>
              a.outcomeId.equals(outcomeId) & a.role.equals('current')))
        .watch()
        .map(_pickWinner);
  }

  /// Current Action text for each of [outcomeIds], keyed by Outcome id. An
  /// absent key means the Outcome is Actionless — the shape the one-at-a-time
  /// review snapshots consume, so a wizard step renders every item's Action
  /// without one DAO call per item.
  ///
  /// Chunked so a large snapshot cannot exceed SQLite's bound-variable limit.
  Future<Map<String, String>> getCurrentActionTexts(
    Set<String> outcomeIds,
  ) async {
    if (outcomeIds.isEmpty) return const {};
    final ids = outcomeIds.toList();
    final byOutcome = <String, List<Action>>{};
    for (var start = 0; start < ids.length; start += _idChunkSize) {
      final chunk = ids.sublist(
        start,
        (start + _idChunkSize).clamp(0, ids.length),
      );
      final rows = await (select(actions)
            ..where((a) => a.outcomeId.isIn(chunk) & a.role.equals('current')))
          .get();
      for (final row in rows) {
        (byOutcome[row.outcomeId] ??= <Action>[]).add(row);
      }
    }
    return {
      for (final entry in byOutcome.entries)
        if (_pickWinner(entry.value) case final winner?)
          entry.key: winner.actionText,
    };
  }

  /// Chunk width for `IN (…)` id lookups, well inside SQLite's default
  /// bound-variable ceiling.
  static const _idChunkSize = 500;

  /// Live view of the Outcome's planned queue, ordered `position, created_at,
  /// id` — the tie-break renders a cross-device duplicate/gap deterministically
  /// without repairing it (writers re-densify; a read never writes).
  Stream<List<Action>> watchPlannedActions(String outcomeId) =>
      _plannedQuery(outcomeId).watch();

  /// One-shot read of the Outcome's planned queue, same ordering as
  /// [watchPlannedActions].
  Future<List<Action>> getPlannedActions(String outcomeId) =>
      _plannedQuery(outcomeId).get();

  SimpleSelectStatement<$ActionsTable, Action> _plannedQuery(
    String outcomeId,
  ) =>
      select(actions)
        ..where((a) => a.outcomeId.equals(outcomeId) & a.role.equals('planned'))
        ..orderBy([
          (a) => OrderingTerm(expression: a.position),
          (a) => OrderingTerm(expression: a.createdAt),
          (a) => OrderingTerm(expression: a.id),
        ]);

  /// Read-side application of the winner rule — deterministic display of an
  /// accidental multi-current set, with nothing written.
  static Action? _pickWinner(List<Action> currents) {
    if (currents.isEmpty) return null;
    if (currents.length == 1) return currents.first;
    return ([...currents]..sort(_winnerFirst)).first;
  }

  // ---------------------------------------------------------------------------
  // Transaction-body variants — run inside the caller's transaction, never
  // notify (the caller notifies after its own commit). Used by the public
  // wrappers above and by TodoDao's dual-write choke points.
  // ---------------------------------------------------------------------------

  Future<ActionWriteEffect> applySetCurrentAction(
    String outcomeId,
    String text, {
    String? energyLevel,
    int? timeEstimate,
    required DateTime ts,
  }) async {
    final normalized = text.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(
        text,
        'text',
        'setCurrentAction requires non-blank text; route a blank write through '
            'clearCurrentAction',
      );
    }
    final resolved = await _resolveCurrentAction(outcomeId, ts);
    final current = resolved.current;

    if (current == null) {
      // D3 (ADR-0001 story 7): energy / time set on an Actionless Outcome live
      // on its columns as draft. When its first `current` Action is born and
      // the caller passes no metadata, seed the birth Action from those draft
      // columns — so the draft lands on the Action for *every* creation path
      // (clarify `applyRouting`, `setNextActionText`,
      // `setNextActionTextIfActionless`) with no signature change. Explicit
      // args win over the draft. This agrees with the sweep's cursor → actions
      // direction (it would have converged to exactly this state).
      var seededEnergy = energyLevel;
      var seededTime = timeEstimate;
      if (seededEnergy == null || seededTime == null) {
        final outcome =
            await (select(todos)..where((t) => t.id.equals(outcomeId)))
                .getSingleOrNull();
        seededEnergy ??= outcome?.energyLevel;
        seededTime ??= outcome?.timeEstimate;
      }
      await _insertCurrentAction(
        outcomeId,
        normalized,
        energyLevel: seededEnergy,
        timeEstimate: seededTime,
        ts: ts,
      );
      await _stampOutcome(outcomeId, ts);
      return (changed: true, stamped: true);
    }

    final textDiffers = current.actionText != normalized;
    final metadataDiffers = (energyLevel != null &&
            energyLevel != current.energyLevel) ||
        (timeEstimate != null && timeEstimate != current.timeEstimate);
    if (!textDiffers && !metadataDiffers) {
      // No-op on the primary write; convergence of an accidental multi-current
      // set (if any) still counts as a change but never stamps.
      return (changed: resolved.converged, stamped: false);
    }

    await (update(actions)..where((a) => a.id.equals(current.id))).write(
      ActionsCompanion(
        actionText: Value(normalized),
        energyLevel:
            energyLevel != null ? Value(energyLevel) : const Value.absent(),
        timeEstimate:
            timeEstimate != null ? Value(timeEstimate) : const Value.absent(),
        updatedAt: Value(ts),
      ),
    );
    await _stampOutcome(outcomeId, ts);
    return (changed: true, stamped: true);
  }

  Future<ActionWriteEffect> applyEditAction(
    String actionId, {
    String? text,
    String? energyLevel,
    int? timeEstimate,
    bool clearEnergyLevel = false,
    bool clearTimeEstimate = false,
    required DateTime ts,
  }) async {
    final row = await (select(actions)..where((a) => a.id.equals(actionId)))
        .getSingleOrNull();
    if (row == null) return _noEffect;

    final normalized = text?.trim();
    final textDiffers = normalized != null && normalized != row.actionText;
    // A clear differs only when the column currently holds a value; setting a
    // value differs when it is not already that value. `clear*` wins over the
    // typed argument, matching [TodoDao.updateFields].
    final energyDiffers = clearEnergyLevel
        ? row.energyLevel != null
        : energyLevel != null && energyLevel != row.energyLevel;
    final timeDiffers = clearTimeEstimate
        ? row.timeEstimate != null
        : timeEstimate != null && timeEstimate != row.timeEstimate;
    if (!textDiffers && !energyDiffers && !timeDiffers) return _noEffect;

    await (update(actions)..where((a) => a.id.equals(actionId))).write(
      ActionsCompanion(
        actionText: textDiffers ? Value(normalized) : const Value.absent(),
        energyLevel: clearEnergyLevel
            ? const Value(null)
            : energyDiffers ? Value(energyLevel) : const Value.absent(),
        timeEstimate: clearTimeEstimate
            ? const Value(null)
            : timeDiffers ? Value(timeEstimate) : const Value.absent(),
        updatedAt: Value(ts),
      ),
    );
    await _stampOutcome(row.outcomeId, ts);
    return (changed: true, stamped: true);
  }

  Future<ActionWriteEffect> applySupersedeCurrentAction(
    String outcomeId, {
    String? newActionText,
    String? newEnergyLevel,
    int? newTimeEstimate,
    required DateTime ts,
  }) async {
    final resolved = await _resolveCurrentAction(outcomeId, ts);
    final current = resolved.current;
    final newText = newActionText?.trim();
    final hasReplacement = newText != null && newText.isNotEmpty;

    var changed = resolved.converged;
    if (current != null) {
      await _retire(current.id, ts);
      changed = true;
    }
    if (hasReplacement) {
      await _insertCurrentAction(
        outcomeId,
        newText,
        energyLevel: newEnergyLevel,
        timeEstimate: newTimeEstimate,
        ts: ts,
      );
      // Cursor dual-write (ADR-0001 story 7, D4): mirror the *replacement's*
      // text + metadata onto the Outcome columns in this same transaction —
      // not the superseded row's. This is mandatory, not defensive: the
      // startup sweep repairs strictly cursor → actions, so a cursor still
      // holding the retired Action's mirrored `energy_level` / `time_estimate`
      // would let mode 1 copy that stale metadata back onto the fresh
      // replacement at the next launch — exactly the inheritance the story
      // forbids. Mirroring makes the subsequent sweep a no-op. The superseded
      // row keeps its own frozen values (history is truthful).
      await (update(todos)..where((t) => t.id.equals(outcomeId))).write(
        TodosCompanion(
          nextActionText: Value(newText),
          energyLevel: Value(newEnergyLevel),
          timeEstimate: Value(newTimeEstimate),
          updatedAt: Value(ts),
        ),
      );
      changed = true;
    }

    // A pure convergence with nothing to supersede and no replacement is repair,
    // not clarification — it must not stamp. Retiring a real current row or
    // minting a replacement is a clarifying act and stamps.
    final didMutate = current != null || hasReplacement;
    if (didMutate) await _stampOutcome(outcomeId, ts);
    return (changed: changed, stamped: didMutate);
  }

  /// Transaction-body variant of [completeCurrentAction], shared with the
  /// Outcome-completion cascade in [TodoDao] so "Outcome done closes its
  /// current Action" is encoded once. Always returns `stamped: false` — the
  /// caller decides whether *its own* act (achieving the Outcome) stamps.
  Future<ActionWriteEffect> applyCompleteCurrentAction(
    String outcomeId, {
    required DateTime ts,
  }) async {
    final resolved = await _resolveCurrentAction(outcomeId, ts);
    final current = resolved.current;
    if (current == null) return (changed: resolved.converged, stamped: false);

    await (update(actions)..where((a) => a.id.equals(current.id))).write(
      ActionsCompanion(
        role: const Value('done'),
        doneAt: Value(ts),
        updatedAt: Value(ts),
      ),
    );
    // Keep the cursor in agreement with the Action side (blank cursor ⟺ no
    // current row) without stamping — see [completeCurrentAction].
    await (update(todos)..where((t) => t.id.equals(outcomeId))).write(
      TodosCompanion(
        nextActionText: const Value(null),
        updatedAt: Value(ts),
      ),
    );
    return (changed: true, stamped: false);
  }

  // ---------------------------------------------------------------------------
  // Planned-queue transaction bodies.
  // ---------------------------------------------------------------------------

  Future<ActionWriteEffect> applyAddPlannedAction(
    String outcomeId,
    String text, {
    String? energyLevel,
    int? timeEstimate,
    int? position,
    required DateTime ts,
  }) async {
    final normalized = text.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(
        text,
        'text',
        'addPlannedAction requires non-blank text',
      );
    }
    final planned = await _plannedActionsFor(outcomeId);
    final int insertAt;
    if (position == null) {
      // Append after the last planned row: COALESCE(MAX(position)+1, 0).
      insertAt = planned.isEmpty
          ? 0
          : planned
                  .map((a) => a.position ?? 0)
                  .reduce((a, b) => a > b ? a : b) +
              1;
    } else {
      insertAt = position.clamp(0, planned.length);
      await _shiftPlannedFrom(planned, insertAt, ts);
    }
    final userId = await _userIdForOutcome(outcomeId);
    await into(actions).insert(
      ActionsCompanion(
        id: Value(uuid.v4()),
        outcomeId: Value(outcomeId),
        userId: Value(userId),
        actionText: Value(normalized),
        role: const Value('planned'),
        position: Value(insertAt),
        energyLevel: Value(energyLevel),
        timeEstimate: Value(timeEstimate),
        createdAt: Value(ts),
        updatedAt: Value(ts),
      ),
    );
    await _stampOutcome(outcomeId, ts);
    return (changed: true, stamped: true);
  }

  Future<ActionWriteEffect> applyReorderPlannedActions(
    String outcomeId,
    List<String> orderedIds, {
    required DateTime ts,
  }) async {
    final planned = await _plannedActionsFor(outcomeId);
    if (planned.isEmpty) return _noEffect;

    final byId = {for (final row in planned) row.id: row};
    final seen = <String>{};
    final target = <Action>[];
    for (final id in orderedIds) {
      final row = byId[id];
      if (row != null && seen.add(id)) target.add(row);
    }
    // Any planned row absent from orderedIds keeps its prior relative order.
    for (final row in planned) {
      if (seen.add(row.id)) target.add(row);
    }

    // No-op when every row already sits at its target dense index; a row at the
    // wrong index means the order changed *or* positions had drifted (gap /
    // duplicate) — either way this write re-densifies.
    var changed = false;
    for (var i = 0; i < target.length; i++) {
      if (target[i].position != i) {
        changed = true;
        break;
      }
    }
    if (!changed) return _noEffect;

    for (var i = 0; i < target.length; i++) {
      if (target[i].position != i) {
        await (update(actions)..where((a) => a.id.equals(target[i].id))).write(
          ActionsCompanion(position: Value(i), updatedAt: Value(ts)),
        );
      }
    }
    await _stampOutcome(outcomeId, ts);
    return (changed: true, stamped: true);
  }

  Future<ActionWriteEffect> applyPromotePlannedAction(
    String actionId, {
    required DateTime ts,
  }) async {
    final row = await (select(actions)..where((a) => a.id.equals(actionId)))
        .getSingleOrNull();
    if (row == null || row.role != 'planned') return _noEffect;

    final resolved = await _resolveCurrentAction(row.outcomeId, ts);
    if (resolved.current != null) {
      throw StateError(
        'promotePlannedAction: Outcome ${row.outcomeId} already has a current '
        'Action; use supersedeAndPromote to replace it',
      );
    }
    await _promoteRow(row, ts);
    await _stampOutcome(row.outcomeId, ts);
    return (changed: true, stamped: true);
  }

  Future<ActionWriteEffect> applySupersedeAndPromote(
    String actionId, {
    required DateTime ts,
  }) async {
    final row = await (select(actions)..where((a) => a.id.equals(actionId)))
        .getSingleOrNull();
    if (row == null || row.role != 'planned') return _noEffect;

    final resolved = await _resolveCurrentAction(row.outcomeId, ts);
    if (resolved.current != null) await _retire(resolved.current!.id, ts);
    await _promoteRow(row, ts);
    await _stampOutcome(row.outcomeId, ts);
    return (changed: true, stamped: true);
  }

  Future<ActionWriteEffect> applyDemoteCurrentAction(
    String actionId, {
    int? position,
    required DateTime ts,
  }) async {
    final row = await (select(actions)..where((a) => a.id.equals(actionId)))
        .getSingleOrNull();
    if (row == null || row.role != 'current') return _noEffect;

    final planned = await _plannedActionsFor(row.outcomeId);
    final insertAt = (position ?? 0).clamp(0, planned.length);
    await _shiftPlannedFrom(planned, insertAt, ts);
    await (update(actions)..where((a) => a.id.equals(row.id))).write(
      ActionsCompanion(
        role: const Value('planned'),
        position: Value(insertAt),
        updatedAt: Value(ts),
      ),
    );
    // Cursor dual-write: clearing the text keeps the sweep from resurrecting the
    // demoted Action as a fresh deterministic current (Pass A mode-3).
    await (update(todos)..where((t) => t.id.equals(row.outcomeId))).write(
      TodosCompanion(
        nextActionText: const Value(null),
        updatedAt: Value(ts),
      ),
    );
    await _stampOutcome(row.outcomeId, ts);
    return (changed: true, stamped: true);
  }

  Future<ActionWriteEffect> applyRemovePlannedAction(
    String actionId, {
    required DateTime ts,
  }) async {
    final row = await (select(actions)..where((a) => a.id.equals(actionId)))
        .getSingleOrNull();
    if (row == null || row.role != 'planned') return _noEffect;

    await (delete(actions)..where((a) => a.id.equals(actionId))).go();
    // The gap the delete leaves in `position` is display-only: the read
    // tie-break covers it and the next reorder re-densifies.
    await _stampOutcome(row.outcomeId, ts);
    return (changed: true, stamped: true);
  }

  // ---------------------------------------------------------------------------
  // Shared internals.
  // ---------------------------------------------------------------------------

  Future<List<Action>> _currentActionsFor(String outcomeId) {
    return (select(actions)
          ..where((a) => a.outcomeId.equals(outcomeId) & a.role.equals('current')))
        .get();
  }

  /// The Outcome's planned rows, in queue order (shared by the planned-queue
  /// transaction bodies, which read then rewrite positions).
  Future<List<Action>> _plannedActionsFor(String outcomeId) =>
      _plannedQuery(outcomeId).get();

  /// Re-densify the planned queue and open slot [from] for a fresh row. Each
  /// ordered row lands at its dense index, with rows at or after [from] pushed
  /// one slot down; the caller then writes the incoming row at [from].
  ///
  /// [from] is a queue *index* (into the ordered [planned] list), not a raw
  /// stored `position`. Comparing index against index — rather than index
  /// against stored `position` — keeps placement correct even when stored
  /// positions have gaps or don't start at 0 (a remove leaves a gap; a
  /// cross-device sync can duplicate). Callers pass the pre-read [planned] list
  /// in queue order to avoid a re-query inside the transaction.
  Future<void> _shiftPlannedFrom(
    List<Action> planned,
    int from,
    DateTime ts,
  ) async {
    for (var i = 0; i < planned.length; i++) {
      final row = planned[i];
      final desired = i >= from ? i + 1 : i;
      if (row.position != desired) {
        await (update(actions)..where((a) => a.id.equals(row.id))).write(
          ActionsCompanion(position: Value(desired), updatedAt: Value(ts)),
        );
      }
    }
  }

  /// Flip [row] to `role='current'` (clearing `position`) and write the cursor
  /// per the promote dual-write rule: text plus a mirror of the promoted row's
  /// `energy_level` / `time_estimate`. Shared by [applyPromotePlannedAction] and
  /// [applySupersedeAndPromote]; the caller stamps.
  Future<void> _promoteRow(Action row, DateTime ts) async {
    await (update(actions)..where((a) => a.id.equals(row.id))).write(
      ActionsCompanion(
        role: const Value('current'),
        position: const Value(null),
        updatedAt: Value(ts),
      ),
    );
    await (update(todos)..where((t) => t.id.equals(row.outcomeId))).write(
      TodosCompanion(
        nextActionText: Value(row.actionText),
        energyLevel: Value(row.energyLevel),
        timeEstimate: Value(row.timeEstimate),
        updatedAt: Value(ts),
      ),
    );
  }

  /// The single surviving `current` Action for [outcomeId], converging an
  /// accidental multi-current set first.
  ///
  /// The 0..1-current invariant is app-enforced (no partial unique index — see
  /// `action_routes.py`), so a cross-device race can sync in two `current`
  /// rows. Any primitive that touches the current Action converges first: keep
  /// the winner by greatest `COALESCE(updated_at, created_at)`, tie-break
  /// smallest `id`; retire the rest. The rule is deterministic, so every device
  /// converges on the same winner. Convergence is repair, not clarification —
  /// it never stamps.
  Future<({Action? current, bool converged})> _resolveCurrentAction(
    String outcomeId,
    DateTime ts,
  ) async {
    final currents = await _currentActionsFor(outcomeId);
    if (currents.isEmpty) return (current: null, converged: false);
    if (currents.length == 1) return (current: currents.first, converged: false);

    final ordered = [...currents]..sort(_winnerFirst);
    final winner = ordered.first;
    for (final loser in ordered.skip(1)) {
      await _retire(loser.id, ts);
    }
    return (current: winner, converged: true);
  }

  /// Orders current rows winner-first: greatest `COALESCE(updated_at,
  /// created_at)`, tie-break smallest id.
  static int _winnerFirst(Action a, Action b) {
    final at = a.updatedAt ?? a.createdAt;
    final bt = b.updatedAt ?? b.createdAt;
    final byTime = bt.compareTo(at); // descending: greatest first
    if (byTime != 0) return byTime;
    return a.id.compareTo(b.id); // ascending: smallest id first
  }

  Future<void> _insertCurrentAction(
    String outcomeId,
    String text, {
    String? energyLevel,
    int? timeEstimate,
    required DateTime ts,
  }) async {
    final userId = await _userIdForOutcome(outcomeId);
    await into(actions).insert(
      ActionsCompanion(
        id: Value(uuid.v4()),
        outcomeId: Value(outcomeId),
        userId: Value(userId),
        actionText: Value(text),
        role: const Value('current'),
        energyLevel: Value(energyLevel),
        timeEstimate: Value(timeEstimate),
        createdAt: Value(ts),
        updatedAt: Value(ts),
      ),
    );
  }

  /// Flip a row to `role='superseded'` with `updated_at = ts` — no linkage
  /// columns (ADR-0018).
  Future<void> _retire(String actionId, DateTime ts) async {
    await (update(actions)..where((a) => a.id.equals(actionId))).write(
      ActionsCompanion(
        role: const Value('superseded'),
        updatedAt: Value(ts),
      ),
    );
  }

  /// The stamping rule, encoded once: an Action mutation is a clarifying
  /// micro-act, so it moves `last_clarified_at` (CONTEXT.md § Clarification).
  Future<void> _stampOutcome(String outcomeId, DateTime ts) async {
    await (update(todos)..where((t) => t.id.equals(outcomeId))).write(
      TodosCompanion(
        lastClarifiedAt: Value(ts),
        updatedAt: Value(ts),
      ),
    );
  }

  Future<String> _userIdForOutcome(String outcomeId) async {
    final row = await (select(todos)..where((t) => t.id.equals(outcomeId)))
        .getSingle();
    return row.userId;
  }
}
