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
/// / `superseded_at`. A text edit of the current Action is an *in-place* edit
/// of the same row (a refinement of the same Action); supersession is an
/// explicit affordance that flips `role` and is exercised only by tests in this
/// story (no UI calls it yet — stories 5/8).
///
/// The dual-write choke points in [TodoDao] compose these primitives through
/// the `apply*` transaction-body variants (package-internal), which run inside
/// the caller's transaction and defer notification to the caller (so watchers
/// never re-read pre-commit state) — see `TodoDao.setNextActionText` /
/// `setNextActionTextIfActionless` / `applyRouting` / `deleteOutcome`.
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
