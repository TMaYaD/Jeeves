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
/// * self-notifies after commit (ADR-0010): the GTD surfaces read across
///   `todos`, `actions` and `time_logs`, so a watcher naming one has to hear
///   about a write to another — the write path calls
///   [GtdDatabase.notifyActionsViewWrite] itself, plus
///   [GtdDatabase.notifyTodosViewWrite] whether or not it touched `todos`.
///
/// **The one exception to the stamping rule is [completeCurrentAction]**
/// (ADR-0001 story 4): finishing the current Action is an *engagement* signal,
/// not a clarifying act (CONTEXT.md § Clarification), so it must leave
/// `last_clarified_at` where it is — that is exactly what makes the Outcome owe
/// a re-clarification the moment its Action is done. It writes nothing to
/// `todos` at all, so its `todos` notification cannot be gated on `stamped`
/// (always false here) and is issued unconditionally instead.
///
/// Per **ADR-0018** supersession carries no linkage metadata: a superseded
/// row's terminal timestamp is its `updated_at`, there is no `superseded_by_id`
/// / `superseded_at`. A text edit of an Action is an *in-place* edit of the
/// same row (a refinement of the same Action); supersession is an explicit
/// affordance that flips `role`. It is now UI-reachable through
/// [supersedeAndPromote] — the "Replace current action" gesture of the planned
/// queue (ADR-0004 story 5) and through [clearCurrentAction], which backs the
/// **Abandon** affordance of the Outcome detail view (story 8, issue #478) — so
/// it is no longer test-only.
///
/// **History (story 8, issue #478).** Terminated Actions stay attached to their
/// Outcome and are read back newest-first by [watchTerminatedActions]. A
/// terminated row is a record: nothing re-promotes it, edits it, or deletes it
/// (ADR-0018 + ADR-0004 — the promote primitive refuses any role but
/// `planned`), and no successor link exists to render.
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
/// **The `actions` table is the only grain.** The legacy
/// `todos.next_action_text` cursor was retired by abandonment (ADR-0022, issue
/// #479) and then dropped from the schema outright (ADR-0024, issue #525). A
/// future contributor who re-adds an Outcome-column mirror of the current
/// Action's text, to keep two sides agreeing, would be re-introducing the
/// second source of truth this model exists to remove.
///
/// What primitives *do* still mirror onto `todos` is Action **metadata**
/// (`energy_level` / `time_estimate`), which is a separate mechanism with a
/// live reader: the per-field D2 COALESCE fallback. See
/// [applySupersedeCurrentAction], [_promoteRow] and [applyEditAction] — the
/// last of which mirrors whenever the row it edits is `current`, so no caller
/// has to know a row's role to keep D1.
///
/// The legacy one-field surfaces in [TodoDao] compose these primitives through
/// the `apply*` transaction-body variants (package-internal), which run inside
/// the caller's transaction and defer notification to the caller (so watchers
/// never re-read pre-commit state) — see `TodoDao.setCurrentActionText` /
/// `setCurrentActionTextIfActionless` / `applyRouting` / `deleteOutcome`.
library;

import 'package:drift/drift.dart';
import '../../utils/uuid.dart';

import '../../sync/collection_codecs.dart';
import '../gtd_database.dart';
import 'time_log_dao.dart' show TimeLogDao;

part 'action_dao.g.dart';

/// The effect of an Action apply-step, so a caller can notify precisely after
/// its own transaction commits: [changed] iff any `actions` row was written,
/// [stamped] iff `last_clarified_at` was moved on the Outcome, [logChanged] iff
/// a `time_logs` row was written by the terminal-transition hook (issue #476) —
/// which the caller uses to fire the TimeLog notification, since the active-log
/// and time-spent watchers do not name `actions` (ADR-0010).
typedef ActionWriteEffect = ({bool changed, bool stamped, bool logChanged});

const ActionWriteEffect _noEffect =
    (changed: false, stamped: false, logChanged: false);

/// One row of an Outcome's history (ADR-0001 story 8, issue #478): a terminated
/// [Action] with the minutes logged against *that* Action, derived at read time
/// from `time_logs` ([TimeLogDao.totalMinutesSubqueryForAction]) rather than
/// stored anywhere.
typedef TerminatedAction = ({Action action, int loggedMinutes});

@DriftAccessor(tables: [Actions, Todos, TimeLogs])
class ActionDao extends DatabaseAccessor<GtdDatabase> with _$ActionDaoMixin {
  ActionDao(super.db);

  // ---------------------------------------------------------------------------
  // Op-log capture (#550). Capture rides at the *effect* level: the `apply*`
  // transaction bodies and the private row mutations they share
  // (`_promoteRow`, `_retire`, `_insertCurrentAction`, `_stampOutcome`,
  // `_closeOpenLogFor` / `_reopenLogAgainst`, `_shiftPlannedFrom`) each
  // describe what they wrote, so every public wrapper inherits coverage from
  // the effect it delegates to. The public wrappers open the capture scope.
  //
  // The multi-current repair (`_resolveCurrentAction`) goes through the seam
  // like any other write: the reducer never knows the single-current
  // invariant, so a repair has to be an ordinary op.
  // ---------------------------------------------------------------------------

  void _captureAction(String actionId, Map<String, Object?> fields) {
    attachedDatabase.opCapture.write(
      collection: actionsCollection,
      entityId: actionId,
      fields: fields,
    );
  }

  void _captureOutcome(String outcomeId, Map<String, Object?> fields) {
    attachedDatabase.opCapture.write(
      collection: todosCollection,
      entityId: outcomeId,
      fields: fields,
    );
  }

  // ---------------------------------------------------------------------------
  // Public primitives — each opens a transaction and notifies after commit.
  // ---------------------------------------------------------------------------

  /// Compatibility-shaped entry point the legacy one-field surfaces drive:
  /// create the Outcome's `current` Action if none exists, otherwise **edit it
  /// in place** (same row, same identity — a text edit is a refinement, never a
  /// supersession; ADR-0018). Identical text with no differing metadata is a
  /// no-op (no write, no stamp, no notify).
  ///
  /// Blank [text] is a caller error here — the legacy one-field shims route a
  /// blank write through [clearCurrentAction] instead.
  Future<void> setCurrentAction(
    String outcomeId,
    String text, {
    String? energyLevel,
    int? timeEstimate,
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await attachedDatabase.capturing(() => transaction(
      () => applySetCurrentAction(
        outcomeId,
        text,
        energyLevel: energyLevel,
        timeEstimate: timeEstimate,
        ts: ts,
      ),
    ));
    _notify(effect);
  }

  /// In-place field edit of an Action by its id — role-agnostic, so it edits a
  /// `current` row (story 7 metadata) or a `planned` row (the planned queue's
  /// inline edit, story 5) with the same UPDATE [setCurrentAction] uses for
  /// text. No-op if the row is gone or nothing differs.
  ///
  /// A `null` typed argument is "no change"; pass the matching `clear*` flag to
  /// null a nullable metadata column (same convention as [TodoDao.updateFields],
  /// which drives this in the same transaction for the metadata mirror).
  ///
  /// Editing a `current` row is safe: [applyEditAction] mirrors the resulting
  /// effort values onto the Outcome columns itself, so D1 holds whatever the
  /// row's role turns out to be at write time.
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
    final effect = await attachedDatabase.capturing(() => transaction(
      () => applyEditAction(
        actionId,
        text: text,
        energyLevel: energyLevel,
        timeEstimate: timeEstimate,
        clearEnergyLevel: clearEnergyLevel,
        clearTimeEstimate: clearTimeEstimate,
        ts: ts,
      ),
    ));
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
    final effect = await attachedDatabase.capturing(() => transaction(
      () => applySupersedeCurrentAction(
        outcomeId,
        newActionText: newActionText,
        newEnergyLevel: newEnergyLevel,
        newTimeEstimate: newTimeEstimate,
        ts: ts,
      ),
    ));
    _notify(effect);
  }

  /// Make the Outcome Actionless: [supersedeCurrentAction] with no replacement.
  /// Retires the current Action, so the Outcome carries none. No current row →
  /// no-op (no stamp). This is the Action side of `setCurrentActionText('')`'s
  /// blank→Actionless normalisation.
  Future<void> clearCurrentAction(String outcomeId, {DateTime? now}) =>
      supersedeCurrentAction(outcomeId, now: now);

  /// Record the current Action as **done** (ADR-0001 story 4): flip it to
  /// `role='done'` with `done_at`, and leave the Outcome in the no-current-
  /// Action state (ADR-0004 — nothing is auto-promoted; the user re-clarifies).
  ///
  /// Deliberately does **not** stamp `Outcome.last_clarified_at`: completion is
  /// the engagement signal, not clarification, so the Outcome immediately
  /// satisfies the re-clarify predicate. It writes nothing to `todos` at all.
  ///
  /// No-op on an Actionless Outcome, and idempotent: a replay finds no current
  /// row and writes nothing, so a completion can never produce two terminal
  /// rows or push the completion timestamp forward.
  Future<void> completeCurrentAction(String outcomeId, {DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await attachedDatabase.capturing(() => transaction(
      () => applyCompleteCurrentAction(outcomeId, ts: ts),
    ));
    if (effect.changed) {
      attachedDatabase.notifyActionsViewWrite();
      // Deliberately notify the `todos` view even though this transaction no
      // longer writes `todos` (the cursor clear is gone): the Outcome's own
      // list membership changes when its Action completes, and two watchers
      // list only `{todoTags, tags}` in `readsFrom`, so they would never see an
      // `actions`-only notification. This cannot ride on
      // [ActionWriteEffect.stamped], which is always false here (ADR-0010).
      attachedDatabase.notifyTodosViewWrite();
    }
    // Completing the Action closes its open TimeLog (issue #476); the `time_logs`
    // view needs the same explicit notify as the other views (ADR-0010).
    if (effect.logChanged) attachedDatabase.notifyTimeLogsViewWrite();
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
    final effect = await attachedDatabase.capturing(() => transaction(
      () => applyAddPlannedAction(
        outcomeId,
        text,
        energyLevel: energyLevel,
        timeEstimate: timeEstimate,
        position: position,
        ts: ts,
      ),
    ));
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
    final effect = await attachedDatabase.capturing(() => transaction(
      () => applyReorderPlannedActions(outcomeId, orderedIds, ts: ts),
    ));
    _notify(effect);
  }

  /// Promote a `planned` Action to `current`. Refuses (`StateError`) when the
  /// Outcome already has a current Action — the caller must use
  /// [supersedeAndPromote] for the replacing variant, so no code path silently
  /// replaces a current (ADR-0004). No-op if the row is gone, is not `planned`,
  /// or is already `current` (idempotent under double-tap / replay). Stamps.
  Future<void> promotePlannedAction(String actionId, {DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await attachedDatabase.capturing(() => transaction(
      () => applyPromotePlannedAction(actionId, ts: ts),
    ));
    _notify(effect);
  }

  /// The "Replace current action" gesture: in one transaction retire the
  /// Outcome's current Action (`role='superseded'`, ADR-0018 — terminal time is
  /// `updated_at`, no linkage) and flip the `planned` [actionId] up to
  /// `current`. No-op if the row is gone, already `current`, or not `planned`.
  /// Stamps once.
  Future<void> supersedeAndPromote(String actionId, {DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await attachedDatabase.capturing(() => transaction(
      () => applySupersedeAndPromote(actionId, ts: ts),
    ));
    _notify(effect);
  }

  /// Demote the current Action [actionId] back into the planned queue at
  /// [position] (default 0 — front of the queue, the just-committed thought
  /// stays the most-likely next candidate), shifting the existing planned rows
  /// down. No-op if the row is gone or is not `current`. Stamps.
  Future<void> demoteCurrentAction(
    String actionId, {
    int? position,
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await attachedDatabase.capturing(() => transaction(
      () => applyDemoteCurrentAction(actionId, position: position, ts: ts),
    ));
    _notify(effect);
  }

  /// Hard-delete a `planned` Action (user-intent removal of an unengaged note —
  /// a planned row carries no engagement or history worth a `superseded`
  /// tombstone, ADR-0004 story 5). No-op — and never a delete — if the row is
  /// gone or is not `planned`. Stamps.
  Future<void> removePlannedAction(String actionId, {DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await attachedDatabase.capturing(() => transaction(
      () => applyRemovePlannedAction(actionId, ts: ts),
    ));
    _notify(effect);
  }

  void _notify(ActionWriteEffect effect) {
    if (effect.changed) attachedDatabase.notifyActionsViewWrite();
    if (effect.stamped) attachedDatabase.notifyTodosViewWrite();
    // The terminal-transition hook (issue #476) writes `time_logs` inside the
    // Action transaction, and its watchers do not name `actions` — so they need
    // the same explicit post-commit notification (ADR-0010).
    if (effect.logChanged) attachedDatabase.notifyTimeLogsViewWrite();
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

  /// The id of [outcomeId]'s winning `current` Action, or null when it is
  /// Actionless. Uses the blessed winner-first ordering ([winnerFirstOrderSql])
  /// so a transient multi-current race attributes to the same row every reader
  /// would display. Runs on [db]'s executor — pass the calling DAO so the read
  /// joins the caller's open transaction (Drift zone routing), which is what
  /// lets a log-opening writer resolve the Action atomically with its insert.
  ///
  /// Single home for the resolution rule so it can't drift between the two
  /// TimeLog writers ([TimeLogDao.openLog] and [FocusSessionDao.setCurrentTask]).
  static Future<String?> currentActionIdFor(
    DatabaseConnectionUser db,
    String outcomeId,
  ) async {
    final row = await db.customSelect(
      "SELECT id FROM actions WHERE outcome_id = ? AND role = 'current' "
      "$winnerFirstOrderSql LIMIT 1",
      variables: [Variable<String>(outcomeId)],
    ).getSingleOrNull();
    return row?.read<String?>('id');
  }

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

  /// The Outcome's **history** (ADR-0001 story 8, issue #478): its terminated
  /// Actions — `done` and `superseded` alike — newest-first, each carrying the
  /// minutes logged against it.
  ///
  /// The terminal timestamp is `COALESCE(done_at, updated_at, created_at)`: a
  /// `done` row's is `done_at`, a `superseded` row's is `updated_at` (ADR-0018
  /// gives supersession no dedicated column), and `created_at` catches a row
  /// that carries neither. Ties break on `id ASC`, mirroring
  /// [winnerFirstOrderSql], so two devices render the same order.
  ///
  /// Deliberately *not* shared with `TodoDao`'s Stale predicate, which uses the
  /// same COALESCE over a different role set — Stale excludes `superseded`
  /// (an abandoned Action owes nothing), history includes it. The expressions
  /// look alike and mean different things; unifying them would be a bug.
  ///
  /// Pure SELECT: no transaction, no stamp, no convergence, no notify —
  /// reading history is not clarification. Drift tracks `actions` for
  /// re-emission; the joined `time_logs` subquery is *not* tracked, which is
  /// sound because every terminal transition closes that Action's log inside
  /// the same transaction (issue #476) and nothing ever opens a log against a
  /// non-`current` row, so a terminated Action's minutes are frozen.
  Stream<List<TerminatedAction>> watchTerminatedActions(String outcomeId) {
    final (query, loggedMinutes) = _terminatedQuery(outcomeId);
    return query.watch().map((rows) => _readTerminated(rows, loggedMinutes));
  }

  /// One-shot read of the Outcome's history, same shape and ordering as
  /// [watchTerminatedActions].
  Future<List<TerminatedAction>> getTerminatedActions(String outcomeId) async {
    final (query, loggedMinutes) = _terminatedQuery(outcomeId);
    return _readTerminated(await query.get(), loggedMinutes);
  }

  /// The two terminal roles. A `planned` row is unengaged thinking and a
  /// `current` row is the live Action; neither is history.
  static const _terminalRoles = ['done', 'superseded'];

  // Drift's `join` erases the row type (its return is the raw
  // `JoinedSelectStatement`), so the added column travels back alongside the
  // statement — reading it needs the very same expression instance.
  (JoinedSelectStatement, Expression<int>) _terminatedQuery(String outcomeId) {
    // Single joined query with an added column, not one lookup per row: an
    // Outcome with a long history would otherwise cost N round-trips.
    final loggedMinutes = CustomExpression<int>(
      TimeLogDao.totalMinutesSubqueryForAction('actions.id'),
    );
    final query = select(actions).join(<Join>[])
      ..addColumns([loggedMinutes])
      ..where(actions.outcomeId.equals(outcomeId) &
          actions.role.isIn(_terminalRoles))
      ..orderBy([
        OrderingTerm(
          expression: coalesce([actions.doneAt, actions.updatedAt, actions.createdAt]),
          mode: OrderingMode.desc,
        ),
        OrderingTerm(expression: actions.id),
      ]);
    return (query, loggedMinutes);
  }

  List<TerminatedAction> _readTerminated(
    List<TypedResult> rows,
    Expression<int> loggedMinutes,
  ) =>
      [
        for (final row in rows)
          (
            action: row.readTable(actions),
            loggedMinutes: row.read(loggedMinutes) ?? 0,
          ),
      ];

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
  // wrappers above and by TodoDao's writers, for which the `actions` table is
  // the only grain — the `todos.next_action_text` cursor is retired and no
  // longer exists (ADR-0022, ADR-0024).
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
      // (clarify `applyRouting`, `setCurrentActionText`,
      // `setCurrentActionTextIfActionless`) with no signature change. Explicit
      // args win over the draft.
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
      return (changed: true, stamped: true, logChanged: false);
    }

    final textDiffers = current.actionText != normalized;
    final metadataDiffers = (energyLevel != null &&
            energyLevel != current.energyLevel) ||
        (timeEstimate != null && timeEstimate != current.timeEstimate);
    if (!textDiffers && !metadataDiffers) {
      // No-op on the primary write; convergence of an accidental multi-current
      // set (if any) still counts as a change but never stamps.
      return (changed: resolved.converged, stamped: false, logChanged: false);
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
    _captureAction(current.id, {
      'text': normalized,
      'energy_level': ?energyLevel,
      'time_estimate': ?timeEstimate,
      'updated_at': encodeInstant(ts),
    });
    await _stampOutcome(outcomeId, ts);
    return (changed: true, stamped: true, logChanged: false);
  }

  /// **Upholds D1 for `current` rows by construction.** When the row it loaded
  /// is `role='current'`, the post-write effort values are mirrored onto
  /// `todos.energy_level` / `time_estimate` in the same transaction — the same
  /// mirror [_promoteRow] writes, for the same D2 reason. That makes D1 a
  /// property of this method rather than of caller discipline: a `planned` row
  /// that became `current` between a sheet opening and its Save (a synced write
  /// from another device, or a promote the UI has not re-emitted yet) can no
  /// longer land effort on the Action while the columns keep the old values,
  /// which would resurface as the Outcome's effective effort the moment the
  /// Action is abandoned. It is idempotent with respect to
  /// [TodoDao.updateFields], which writes the same columns first inside the
  /// same transaction.
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
    _captureAction(actionId, {
      if (textDiffers) 'text': normalized,
      if (clearEnergyLevel)
        'energy_level': null
      else if (energyDiffers)
        'energy_level': energyLevel,
      if (clearTimeEstimate)
        'time_estimate': null
      else if (timeDiffers)
        'time_estimate': timeEstimate,
      'updated_at': encodeInstant(ts),
    });
    if (row.role == 'current') {
      // D1, by construction rather than by caller discipline. Mirror the
      // *post-write* effort values (not the diffs) so the columns cannot be
      // left holding a value the current Action no longer carries — exactly
      // what [_promoteRow] writes, and idempotent when [TodoDao.updateFields]
      // has already written them earlier in this transaction.
      await (update(todos)..where((t) => t.id.equals(row.outcomeId))).write(
        TodosCompanion(
          energyLevel: Value(
            clearEnergyLevel ? null : energyLevel ?? row.energyLevel,
          ),
          timeEstimate: Value(
            clearTimeEstimate ? null : timeEstimate ?? row.timeEstimate,
          ),
          updatedAt: Value(ts),
        ),
      );
      _captureOutcome(row.outcomeId, {
        'energy_level':
            clearEnergyLevel ? null : energyLevel ?? row.energyLevel,
        'time_estimate':
            clearTimeEstimate ? null : timeEstimate ?? row.timeEstimate,
        'updated_at': encodeInstant(ts),
      });
    }
    await _stampOutcome(row.outcomeId, ts);
    return (changed: true, stamped: true, logChanged: false);
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
    // Terminal-transition TimeLog hook (issue #476, CONTEXT.md § Switching
    // Actions: switching closes the current TimeLog and opens a new one).
    // Close the retired Action's open log; if a replacement is minted in the
    // same transaction AND a log was closed, reopen a continuation against the
    // successor so no engagement time is lost. Keep this minimal — #477 also
    // edits this method (a metadata mirror); the two additions are independent.
    TimeLog? closedLog;
    if (current != null) {
      closedLog = await _closeOpenLogFor(current.id, ts);
      await _retire(current.id, ts);
      changed = true;
    }
    if (hasReplacement) {
      final newActionId = await _insertCurrentAction(
        outcomeId,
        newText,
        energyLevel: newEnergyLevel,
        timeEstimate: newTimeEstimate,
        ts: ts,
      );
      // Metadata mirror (ADR-0001 story 7, D4): mirror the *replacement's*
      // `energy_level` / `time_estimate` onto the Outcome columns in this same
      // transaction — not the superseded row's. This is not cursor
      // bookkeeping: the D2 read fallback is a per-field COALESCE over these
      // columns, so leaving the retired Action's estimates behind would let
      // them resurface against the fresh replacement — exactly the inheritance
      // the story forbids. The superseded row keeps its own frozen values
      // (history is truthful).
      await (update(todos)..where((t) => t.id.equals(outcomeId))).write(
        TodosCompanion(
          energyLevel: Value(newEnergyLevel),
          timeEstimate: Value(newTimeEstimate),
          updatedAt: Value(ts),
        ),
      );
      _captureOutcome(outcomeId, {
        'energy_level': newEnergyLevel,
        'time_estimate': newTimeEstimate,
        'updated_at': encodeInstant(ts),
      });
      changed = true;
      if (closedLog != null) {
        await _reopenLogAgainst(closed: closedLog, newActionId: newActionId, ts: ts);
      }
    }

    // A pure convergence with nothing to supersede and no replacement is repair,
    // not clarification — it must not stamp. Retiring a real current row or
    // minting a replacement is a clarifying act and stamps.
    // The *abandon* arm — a retirement with nothing to succeed it — writes
    // nothing to `todos` beyond the stamp below. It used to clear the cursor to
    // stop the startup sweep resurrecting the retired Action; the sweep's
    // cursor-adoption pass is deleted outright (ADR-0022), so nothing reads the
    // cursor to resurrect anything, and the `superseded` row this leaves behind
    // needs no cursor-clear guard at all.
    final didMutate = current != null || hasReplacement;
    if (didMutate) await _stampOutcome(outcomeId, ts);
    // A `time_logs` row was written iff the retired Action had an open log to
    // close (a non-null closedLog); the reopen, when it fires, rides on that.
    return (changed: changed, stamped: didMutate, logChanged: closedLog != null);
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
    if (current == null) {
      return (changed: resolved.converged, stamped: false, logChanged: false);
    }

    await (update(actions)..where((a) => a.id.equals(current.id))).write(
      ActionsCompanion(
        role: const Value('done'),
        doneAt: Value(ts),
        updatedAt: Value(ts),
      ),
    );
    _captureAction(current.id, {
      'role': 'done',
      'done_at': encodeInstant(ts),
      'updated_at': encodeInstant(ts),
    });
    // Engagement on this Action ended at Done — close its open TimeLog here
    // (issue #476), not at a later endFocus(). No reopen: a finished Action has
    // no successor to continue against (CONTEXT.md § Switching Actions).
    final closedLog = await _closeOpenLogFor(current.id, ts);
    // Nothing is written to `todos`: completion must not stamp, and there is
    // no Outcome-column cursor to clear — it was deleted outright (ADR-0022,
    // ADR-0024), along with the adoption pass that would have needed guarding. The caller still
    // fires the `todos` view notification — see [completeCurrentAction].
    return (changed: true, stamped: false, logChanged: closedLog != null);
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
    final plannedId = uuid.v4();
    await into(actions).insert(
      ActionsCompanion(
        id: Value(plannedId),
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
    _captureAction(plannedId, {
      'outcome_id': outcomeId,
      'user_id': userId,
      'text': normalized,
      'role': 'planned',
      'position': insertAt,
      'energy_level': energyLevel,
      'time_estimate': timeEstimate,
      'created_at': encodeInstant(ts),
      'updated_at': encodeInstant(ts),
      'done_at': null,
    });
    await _stampOutcome(outcomeId, ts);
    return (changed: true, stamped: true, logChanged: false);
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
        _captureAction(target[i].id, {
          'position': i,
          'updated_at': encodeInstant(ts),
        });
      }
    }
    await _stampOutcome(outcomeId, ts);
    return (changed: true, stamped: true, logChanged: false);
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
    return (changed: true, stamped: true, logChanged: false);
  }

  Future<ActionWriteEffect> applySupersedeAndPromote(
    String actionId, {
    required DateTime ts,
  }) async {
    final row = await (select(actions)..where((a) => a.id.equals(actionId)))
        .getSingleOrNull();
    if (row == null || row.role != 'planned') return _noEffect;

    final resolved = await _resolveCurrentAction(row.outcomeId, ts);
    // Terminal-transition TimeLog hook (issue #476, CONTEXT.md § Switching
    // Actions): retiring the current Action here is the same transition as in
    // supersedeCurrentAction, so it closes the retired Action's open log and,
    // because the promoted [row] is the installed successor, reopens a
    // continuation against it so no engagement time is lost.
    TimeLog? closedLog;
    final current = resolved.current;
    if (current != null) {
      closedLog = await _closeOpenLogFor(current.id, ts);
      await _retire(current.id, ts);
    }
    await _promoteRow(row, ts);
    if (closedLog != null) {
      await _reopenLogAgainst(closed: closedLog, newActionId: row.id, ts: ts);
    }
    await _stampOutcome(row.outcomeId, ts);
    return (changed: true, stamped: true, logChanged: closedLog != null);
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
    _captureAction(row.id, {
      'role': 'planned',
      'position': insertAt,
      'updated_at': encodeInstant(ts),
    });
    await _stampOutcome(row.outcomeId, ts);
    return (changed: true, stamped: true, logChanged: false);
  }

  Future<ActionWriteEffect> applyRemovePlannedAction(
    String actionId, {
    required DateTime ts,
  }) async {
    final row = await (select(actions)..where((a) => a.id.equals(actionId)))
        .getSingleOrNull();
    if (row == null || row.role != 'planned') return _noEffect;

    await (delete(actions)..where((a) => a.id.equals(actionId))).go();
    // A hard delete on the log is a tombstone op, never row absence — that is
    // what stops a replayed create from resurrecting the removed row.
    attachedDatabase.opCapture
        .tombstone(collection: actionsCollection, entityId: actionId);
    // The gap the delete leaves in `position` is display-only: the read
    // tie-break covers it and the next reorder re-densifies.
    await _stampOutcome(row.outcomeId, ts);
    return (changed: true, stamped: true, logChanged: false);
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
        _captureAction(row.id, {
          'position': desired,
          'updated_at': encodeInstant(ts),
        });
      }
    }
  }

  /// Flip [row] to `role='current'` (clearing `position`) and mirror the
  /// promoted row's `energy_level` / `time_estimate` onto the Outcome so the D2
  /// read fallback resolves to the newly-current Action rather than the one it
  /// replaced. Shared by [applyPromotePlannedAction] and
  /// [applySupersedeAndPromote]; the caller stamps.
  Future<void> _promoteRow(Action row, DateTime ts) async {
    await (update(actions)..where((a) => a.id.equals(row.id))).write(
      ActionsCompanion(
        role: const Value('current'),
        position: const Value(null),
        updatedAt: Value(ts),
      ),
    );
    _captureAction(row.id, {
      'role': 'current',
      'position': null,
      'updated_at': encodeInstant(ts),
    });
    await (update(todos)..where((t) => t.id.equals(row.outcomeId))).write(
      TodosCompanion(
        energyLevel: Value(row.energyLevel),
        timeEstimate: Value(row.timeEstimate),
        updatedAt: Value(ts),
      ),
    );
    _captureOutcome(row.outcomeId, {
      'energy_level': row.energyLevel,
      'time_estimate': row.timeEstimate,
      'updated_at': encodeInstant(ts),
    });
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

  /// Inserts a fresh `current` Action and returns its generated id (the id lets
  /// a supersede reopen a continuation TimeLog against the successor — #476).
  Future<String> _insertCurrentAction(
    String outcomeId,
    String text, {
    String? energyLevel,
    int? timeEstimate,
    required DateTime ts,
  }) async {
    final userId = await _userIdForOutcome(outcomeId);
    final id = uuid.v4();
    await into(actions).insert(
      ActionsCompanion(
        id: Value(id),
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
    _captureAction(id, {
      'outcome_id': outcomeId,
      'user_id': userId,
      'text': text,
      'role': 'current',
      'position': null,
      'energy_level': energyLevel,
      'time_estimate': timeEstimate,
      'created_at': encodeInstant(ts),
      'updated_at': encodeInstant(ts),
      'done_at': null,
    });
    return id;
  }

  /// Close every open TimeLog attributed to [actionId] at [ts], returning the
  /// most-recently-started row that was closed (or null when none was open) so
  /// a supersede can reopen a continuation against the successor Action.
  ///
  /// Scoped to `action_id` — a stint the user already switched away from (open
  /// against a *different* Action) is left untouched. All-open closure is
  /// defensive against a stale multi-open edge; the invariant is one globally.
  Future<TimeLog?> _closeOpenLogFor(String actionId, DateTime ts) async {
    final open = await (select(timeLogs)
          ..where((t) => t.actionId.equals(actionId) & t.endedAt.isNull())
          ..orderBy([(t) => OrderingTerm.desc(t.startedAt)]))
        .get();
    if (open.isEmpty) return null;
    await (update(timeLogs)
          ..where((t) => t.actionId.equals(actionId) & t.endedAt.isNull()))
        .write(TimeLogsCompanion(endedAt: Value(ts.toIso8601String())));
    for (final row in open) {
      TimeLogDao.captureLogClosedOn(attachedDatabase, row.id, ts);
    }
    return open.first;
  }

  /// Reopen a continuation TimeLog against [newActionId], copying the closed
  /// row's `task_id`, `user_id` and `focus_session_id` so engagement continuity
  /// (and session attribution) is preserved with zero seconds lost — the
  /// close-and-reopen rule (CONTEXT.md § Switching Actions).
  Future<void> _reopenLogAgainst({
    required TimeLog closed,
    required String newActionId,
    required DateTime ts,
  }) async {
    final id = uuid.v4();
    await into(timeLogs).insert(
      TimeLogsCompanion(
        id: Value(id),
        userId: Value(closed.userId),
        taskId: Value(closed.taskId),
        actionId: Value(newActionId),
        startedAt: Value(ts.toIso8601String()),
        endedAt: const Value(null),
        focusSessionId: Value(closed.focusSessionId),
      ),
    );
    TimeLogDao.captureLogOpened(
      attachedDatabase,
      id: id,
      userId: closed.userId,
      taskId: closed.taskId,
      actionId: newActionId,
      startedAtIso: ts.toIso8601String(),
      focusSessionId: closed.focusSessionId,
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
    _captureAction(actionId, {
      'role': 'superseded',
      'updated_at': encodeInstant(ts),
    });
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
    _captureOutcome(outcomeId, {
      'last_clarified_at': encodeInstant(ts),
      'updated_at': encodeInstant(ts),
    });
  }

  Future<String> _userIdForOutcome(String outcomeId) async {
    final row = await (select(todos)..where((t) => t.id.equals(outcomeId)))
        .getSingle();
    return row.userId;
  }
}
