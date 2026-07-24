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
///   [GtdDatabase.notifyTodosViewWrite] when it stamped.
///
/// Per **ADR-0018** supersession carries no linkage metadata: a superseded
/// row's terminal timestamp is its `updated_at`, there is no `superseded_by_id`
/// / `superseded_at`. A text edit of the current Action is an *in-place* edit
/// of the same row (a refinement of the same Action); supersession is an
/// explicit affordance that flips `role` and is exercised only by tests in this
/// story (no UI calls it yet — stories 5/8).
///
/// The dual-write choke points in [TodoDao] compose these primitives through
/// the `apply*` transaction-body variants (package-internal), which run inside
/// the caller's transaction and defer notification to the caller (so watchers
/// never re-read pre-commit state) — see `TodoDao.setNextActionText` /
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

  /// In-place field edit of an Action by its id (story 7 uses this for
  /// metadata). Same UPDATE primitive [setCurrentAction] uses for text. No-op
  /// if the row is gone or nothing differs.
  Future<void> editCurrentAction(
    String actionId, {
    String? text,
    String? energyLevel,
    int? timeEstimate,
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await transaction(
      () => applyEditAction(
        actionId,
        text: text,
        energyLevel: energyLevel,
        timeEstimate: timeEstimate,
        ts: ts,
      ),
    );
    _notify(effect);
  }

  /// The explicit-affordance primitive (ADR-0018): flip the Outcome's current
  /// Action to `role='superseded'` (no linkage columns — the terminal time is
  /// `updated_at`), then, if [newActionText] is non-blank, mint a fresh
  /// `current` row. No UI calls this in this story (Abandon / re-clarify-to-new
  /// are stories 5/8); it is exercised by tests, and by [clearCurrentAction].
  Future<void> supersedeCurrentAction(
    String outcomeId, {
    String? newActionText,
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await transaction(
      () => applySupersedeCurrentAction(
        outcomeId,
        newActionText: newActionText,
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

  void _notify(ActionWriteEffect effect) {
    if (effect.changed) attachedDatabase.notifyActionsViewWrite();
    if (effect.stamped) attachedDatabase.notifyTodosViewWrite();
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
      await _insertCurrentAction(
        outcomeId,
        normalized,
        energyLevel: energyLevel,
        timeEstimate: timeEstimate,
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
    required DateTime ts,
  }) async {
    final row = await (select(actions)..where((a) => a.id.equals(actionId)))
        .getSingleOrNull();
    if (row == null) return _noEffect;

    final normalized = text?.trim();
    final textDiffers = normalized != null && normalized != row.actionText;
    final energyDiffers = energyLevel != null && energyLevel != row.energyLevel;
    final timeDiffers = timeEstimate != null && timeEstimate != row.timeEstimate;
    if (!textDiffers && !energyDiffers && !timeDiffers) return _noEffect;

    await (update(actions)..where((a) => a.id.equals(actionId))).write(
      ActionsCompanion(
        actionText: textDiffers ? Value(normalized) : const Value.absent(),
        energyLevel:
            energyDiffers ? Value(energyLevel) : const Value.absent(),
        timeEstimate:
            timeDiffers ? Value(timeEstimate) : const Value.absent(),
        updatedAt: Value(ts),
      ),
    );
    await _stampOutcome(row.outcomeId, ts);
    return (changed: true, stamped: true);
  }

  Future<ActionWriteEffect> applySupersedeCurrentAction(
    String outcomeId, {
    String? newActionText,
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
      await _insertCurrentAction(outcomeId, newText, ts: ts);
      changed = true;
    }

    // A pure convergence with nothing to supersede and no replacement is repair,
    // not clarification — it must not stamp. Retiring a real current row or
    // minting a replacement is a clarifying act and stamps.
    final didMutate = current != null || hasReplacement;
    if (didMutate) await _stampOutcome(outcomeId, ts);
    return (changed: changed, stamped: didMutate);
  }

  // ---------------------------------------------------------------------------
  // Shared internals.
  // ---------------------------------------------------------------------------

  Future<List<Action>> _currentActionsFor(String outcomeId) {
    return (select(actions)
          ..where((a) => a.outcomeId.equals(outcomeId) & a.role.equals('current')))
        .get();
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
