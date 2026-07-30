/// Drift table declarations for the domain read model.
///
/// Drift owns this schema outright — see `gtd_database.dart`. Which of these
/// tables the op-log spine carries is declared in `sync/collection_codecs.dart`,
/// the one registry that decides what travels on the wire; there is no marker on
/// the table classes, because a build-time marker and a runtime codec map are two
/// answers to one question.
library;

import 'package:drift/drift.dart';
import '../utils/uuid.dart';

// ---------------------------------------------------------------------------
// todos
// ---------------------------------------------------------------------------

class Todos extends Table {
  TextColumn get id => text().clientDefault(() => uuid.v4())();
  TextColumn get title => text().withLength(max: 500)();
  TextColumn get notes => text().nullable()();
  IntColumn get priority => integer().nullable()();
  DateTimeColumn get dueDate => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime().nullable()();

  /// ISO-8601 UTC timestamp; non-null when the task has been completed.
  TextColumn get doneAt => text().nullable()();

  /// Whether this todo has been clarified (processed out of inbox).
  /// false = still in inbox; true = clarified and assigned to a GTD list.
  BoolColumn get clarified =>
      boolean().withDefault(const Constant(true)).clientDefault(() => true)();

  /// Orthogonal intent: next | maybe | trash (migration 0015).
  TextColumn get intent => text()
      .clientDefault(() => 'next')
      .customConstraint(
        "NOT NULL DEFAULT 'next' CHECK (\"intent\" IN ('next','maybe','trash'))",
      )();

  /// Estimated effort in minutes (nullable).
  IntColumn get timeEstimate => integer().nullable()();

  /// Energy required: low | medium | high (nullable).
  TextColumn get energyLevel => text().nullable()();

  /// How this todo entered the inbox: manual | share_sheet | voice | ai_parse (nullable).
  TextColumn get captureSource => text().nullable()();

  TextColumn get locationId => text().nullable()();
  TextColumn get userId => text()();

  /// Timestamp of the last clarifying micro-act on this Outcome.
  ///
  /// Stamped by the DAO whenever the user performs an act of *thinking about
  /// the Outcome* per CONTEXT.md ("Clarification stamps last_clarified_at per
  /// micro-act"). Stamping writes include:
  ///   - Outcome creation (Capture → clarified=true)
  ///   - title / notes / Intent / due-date edits
  ///   - any Action mutation (next-action text, energy, time-estimate, …)
  ///   - PersonBlocker (person-tag) add / remove
  ///   - Outcome completion or trashing (and the reverse: restore)
  ///
  /// Non-stamping writes include current-Action completion (engagement, not
  /// clarification), TimeLog writes, and Area / Label changes (organising).
  /// Drives the re-clarification ("Stale") predicate; see todo_dao.dart's
  /// _needsReviewWhere.
  DateTimeColumn get lastClarifiedAt => dateTime().nullable()();

  /// Cumulative time spent in minutes across all focus stints.
  IntColumn get timeSpentMinutes =>
      integer().withDefault(const Constant(0)).clientDefault(() => 0)();

  /// When a focus session last closed with this task non-done.
  /// Stamped by reviewAndCloseSession. Used to detect staleness vs lastClarifiedAt.
  DateTimeColumn get lastNextActionCompletionAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// time_logs
// ---------------------------------------------------------------------------

/// One row per focus stint on a task.
///
/// Timestamps are ISO-8601 UTC text strings.
/// `ended_at` is null while the stint is still running.
class TimeLogs extends Table {
  /// Supplied by the writer — `TimeLogDao` mints it, so there is no
  /// `clientDefault` to disagree with the id the authored op carries.
  TextColumn get id => text()();
  TextColumn get userId => text()();
  TextColumn get taskId => text().references(Todos, #id)();

  /// The Action engaged when this stint ran (ADR-0001 story 6, issue #476).
  ///
  /// NULL means "no Action attribution available" — a pre-Action-era log, a
  /// defensive Actionless edge where the Outcome had no `current` Action at open
  /// time, or a log whose Action was later deleted (`ON DELETE SET NULL`, so a
  /// deleted Action detaches its logs rather than deleting them). The row still
  /// carries [taskId] (Outcome-grain) attribution, so every time-spent total
  /// (which aggregates by `task_id`) is unaffected either way.
  ///
  /// `onDelete: setNull` matches the backend FK (Alembic 0029): a nullable FK
  /// whose parent-delete rule is SET NULL, never CASCADE (which would destroy
  /// time data) or RESTRICT (which would block the delete).
  TextColumn get actionId =>
      text().nullable().references(Actions, #id, onDelete: KeyAction.setNull)();

  /// ISO-8601 UTC string: when the stint started.
  TextColumn get startedAt => text()();

  /// ISO-8601 UTC string: when the stint ended; null while still running.
  TextColumn get endedAt => text().nullable()();

  /// UUID of the focus session this log row belongs to; null for pre-FocusSession rows.
  TextColumn get focusSessionId =>
      text().nullable().references(FocusSessions, #id)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// focus_sessions
// ---------------------------------------------------------------------------

/// One row per planning session. An open session (ended_at IS NULL) is the
/// single source of truth for "what tasks are on today's plan" and
/// "which task is currently focused."
class FocusSessions extends Table {
  TextColumn get id => text().clientDefault(() => uuid.v4())();
  TextColumn get userId => text()();
  TextColumn get startedAt => text()();
  TextColumn get endedAt => text().nullable()();

  /// The task currently being focused on; null when no task is active.
  TextColumn get currentTaskId =>
      text().nullable().references(Todos, #id)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// focus_session_tasks
// ---------------------------------------------------------------------------

/// Junction table: which todos are part of a focus session, in what order.
class FocusSessionTasks extends Table {
  /// Sync row identifier — not the domain key, which is (focus_session_id,
  /// task_id). The projector realigns it onto
  /// `focusSessionTaskIdFor(sessionId, taskId)` so every device converges on one
  /// row identity regardless of which authored the create (ADR-0025).
  TextColumn get id => text().unique().clientDefault(() => uuid.v4())();
  TextColumn get focusSessionId => text().references(FocusSessions, #id)();
  TextColumn get taskId => text().references(Todos, #id)();
  IntColumn get position => integer()();

  /// Per-task disposition chosen during session review, for **Plan members**.
  /// Off-Plan engaged Outcomes have no row here (the Plan never auto-grows —
  /// ADR-0002); their Dispositions live in [FocusSessionDispositions] instead
  /// (ADR-0016).
  /// NULL = not yet reviewed (active session) or done task.
  /// 'rollover' = carry forward to next session's pre-selected list.
  /// 'leave' = return to Next Actions (no mutation on todos).
  /// 'maybe' = defer; FocusSessionReviewNotifier writes intent='maybe' to todos.
  TextColumn get disposition => text().nullable()();

  /// Denormalized from `focus_sessions.user_id` so a junction row carries its
  /// owner without a JOIN.
  TextColumn get userId => text()();

  @override
  Set<Column<Object>> get primaryKey => {focusSessionId, taskId};
}

// ---------------------------------------------------------------------------
// focus_session_dispositions
// ---------------------------------------------------------------------------

/// Durable home for Review-phase Dispositions on **off-Plan engaged** Outcomes
/// (ADR-0016).
///
/// Dispositions partition by membership class:
///   - A Plan member's Disposition lives on [FocusSessionTasks.disposition]
///     (it already has a junction row from Planning).
///   - An off-Plan engaged Outcome has **no** `focus_session_tasks` row — the
///     Plan is fixed at Planning and never auto-grows from engagement
///     (ADR-0002) — so its Disposition is recorded here, keyed by the
///     (FocusSession, Outcome) pair per CONTEXT.md § Engagement (Disposition is
///     a property of that relationship, independent of Plan membership).
///
/// Query helpers UNION the two homes so callers see one logical Disposition set
/// (`FocusSessionDao.getLastClosedSessionRolloverTaskIds`, the review-surface
/// stamp). Keeping this separate from `focus_session_tasks` preserves the
/// load-bearing invariant "the Plan *is* the set of `focus_session_tasks`
/// rows" — no Plan reader has to remember to filter a discriminator column.
class FocusSessionDispositions extends Table {
  /// Sync row identifier — not the domain key. Required (no random
  /// client default): callers must derive it deterministically via
  /// `focusSessionDispositionIdFor(sessionId, taskId)` (see focus_session_dao.dart)
  /// so re-recording the same pair collapses under INSERT OR REPLACE onto one
  /// stable sync identity instead of accumulating duplicate rows.
  TextColumn get id => text().unique()();
  TextColumn get focusSessionId => text().references(FocusSessions, #id)();
  TextColumn get taskId => text().references(Todos, #id)();

  /// Per-(FocusSession, Outcome) disposition: 'rollover' | 'leave' | 'maybe'.
  /// Same vocabulary as [FocusSessionTasks.disposition]. NULL is unused here —
  /// a row exists only once the user has dispositioned the off-Plan Outcome.
  TextColumn get disposition => text().nullable()();

  /// Denormalized from `focus_sessions.user_id` so a disposition row carries its
  /// owner without a JOIN.
  TextColumn get userId => text()();

  @override
  Set<Column<Object>> get primaryKey => {focusSessionId, taskId};
}

// ---------------------------------------------------------------------------
// tags
// ---------------------------------------------------------------------------

class Tags extends Table {
  TextColumn get id => text().clientDefault(() => uuid.v4())();
  TextColumn get name => text().withLength(max: 100)();
  TextColumn get color => text().nullable()();

  /// GTD discriminator: context | project | area | label | person
  TextColumn get type => text()
      .withDefault(const Constant('context'))
      .clientDefault(() => 'context')();

  TextColumn get userId => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  /// Test-only tripwire against duplicate `(name, type)` rows.
  ///
  /// Drift emits `UNIQUE (name, type)` in the `CREATE TABLE`, so any regression
  /// that mints a second row with the same `(name, type)` fails loudly. The
  /// constraint is local, and convergence is not: two devices can each create
  /// "Home" offline and reduce to two rows, so `TagDao.findOrCreateTag` and the
  /// one-time `dedupeTags` startup pass remain the application-layer half of the
  /// invariant.
  @override
  List<Set<Column<Object>>> get uniqueKeys => [
        {name, type},
      ];
}

// ---------------------------------------------------------------------------
// user_preferences
// ---------------------------------------------------------------------------

/// Cross-device synced key-value preference store.
///
/// One row per (user_id, key) pair. `value` is JSON-encoded; NULL is a
/// tombstone. `updated_at` drives LWW arbitration when local and server rows
/// conflict at sign-in (see MigrationService).
class UserPreferences extends Table {
  TextColumn get id => text().clientDefault(() => uuid.v4())();
  TextColumn get userId => text()();
  TextColumn get key => text()();
  TextColumn get value => text().nullable()();
  TextColumn get updatedAt => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
        {userId, key}
      ];
}

// ---------------------------------------------------------------------------
// todo_tags  (junction)
// ---------------------------------------------------------------------------

class TodoTags extends Table {
  /// A sync row identifier, carried even though the *logical* identity of a
  /// junction row is (todo_id, tag_id): the op log names an entity by one id, so
  /// the pair has to reduce to a single derived one.  Callers should derive it
  /// deterministically via `todoTagIdFor(todoId, tagId)` (see tag_dao.dart)
  /// so re-assigning the same tag collapses under INSERT OR REPLACE instead
  /// of accumulating duplicate rows.
  TextColumn get id => text().unique()();

  TextColumn get todoId => text().references(Todos, #id)();
  TextColumn get tagId => text().references(Tags, #id)();

  /// Denormalized from `todos.user_id` so a junction row carries its owner
  /// without a JOIN.
  TextColumn get userId => text()();

  @override
  Set<Column<Object>> get primaryKey => {todoId, tagId};
}

// ---------------------------------------------------------------------------
// captures
// ---------------------------------------------------------------------------

/// A raw, unprocessed fragment the user put into the system because it has
/// their attention (ADR-0006). Distinct from an Outcome (`todos`): a Capture
/// is pending clarification and is many-to-many with Outcome via
/// [CaptureOutcomes].
///
/// Inbox membership is `clarified_at IS NULL`. Clarifying a Capture stamps
/// `clarified_at` exactly once — whether it produced new Outcomes, merged into
/// existing ones, or was discarded (a zero-Outcome clarification is a
/// legitimate verdict). A stamped Capture is never deleted; it persists as
/// provenance for the Outcomes it clarified into. `last_clarified_at` on the
/// Outcome is a distinct concept (staleness of the *current* clarification)
/// and lives on `todos`, not here.
class Captures extends Table {
  TextColumn get id => text().clientDefault(() => uuid.v4())();
  TextColumn get title => text().withLength(max: 500)();
  TextColumn get notes => text().nullable()();

  /// How this Capture entered the system:
  /// manual | share_sheet | voice | ai_parse | nirvana_import (nullable).
  TextColumn get captureSource => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();

  /// NULL = still in the Inbox. Stamped once when the clarify act completes.
  DateTimeColumn get clarifiedAt => dateTime().nullable()();

  DateTimeColumn get updatedAt => dateTime().nullable()();
  TextColumn get userId => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// capture_outcomes  (provenance join: which Outcomes a Capture clarified into)
// ---------------------------------------------------------------------------

/// Many-to-many provenance link between a [Captures] row and an Outcome
/// (`todos`). The join *is* the provenance — "this Outcome was captured from
/// these N Captures" — there is no separate audit table (ADR-0006). Merge
/// links, never consumes: a Capture keeps its rows here after it is stamped.
class CaptureOutcomes extends Table {
  /// Sync row identifier — not the domain key. Derive it
  /// deterministically via `captureOutcomeIdFor(captureId, outcomeId)`
  /// (see capture_dao.dart) so a repeat link is a stable no-op under INSERT OR
  /// IGNORE (preserving the original `created_at`) instead of accumulating
  /// duplicate rows.
  TextColumn get id => text().unique()();
  TextColumn get captureId =>
      text().references(Captures, #id, onDelete: KeyAction.cascade)();
  TextColumn get outcomeId =>
      text().references(Todos, #id, onDelete: KeyAction.cascade)();

  /// When the link was made — the clarifying micro-act that carved (or merged
  /// into) this Outcome.
  DateTimeColumn get createdAt => dateTime()();

  /// Denormalized from the parent's `user_id` so a junction row carries its
  /// owner without a JOIN.
  TextColumn get userId => text()();

  @override
  Set<Column<Object>> get primaryKey => {captureId, outcomeId};
}

// ---------------------------------------------------------------------------
// capture_tags  (tag hints carried from capture time)
// ---------------------------------------------------------------------------

/// Tag *hints* a Capture carried from capture time. Distinct from Organising:
/// tag hints never stamp anything and are not List membership — they surface
/// only as removable chips on the Outcome draft at clarify time and as prefill
/// when merging into an existing Outcome (issue #184). Mirrors `todo_tags`
/// conventions.
class CaptureTags extends Table {
  /// Sync row identifier — derive it deterministically via
  /// `captureTagIdFor(captureId, tagId)` (see capture_dao.dart).
  TextColumn get id => text().unique()();
  TextColumn get captureId =>
      text().references(Captures, #id, onDelete: KeyAction.cascade)();
  TextColumn get tagId =>
      text().references(Tags, #id, onDelete: KeyAction.cascade)();

  /// Denormalized from the parent's `user_id` for the per-user bucket.
  TextColumn get userId => text()();

  @override
  Set<Column<Object>> get primaryKey => {captureId, tagId};
}

// ---------------------------------------------------------------------------
// actions
// ---------------------------------------------------------------------------

/// A first-class Action against an Outcome (`todos`) — ADR-0001, story 1
/// (issue #471). An owned entity (client-declared `id`, like [Captures]),
/// distinct from the Outcome it belongs to, carrying one of four roles over
/// its lifetime: `planned` / `current` / `done` / `superseded`.
///
/// Per ADR-0018 a superseded Action carries **no** linkage metadata — no
/// `superseded_by_id`, no dedicated `superseded_at`; a superseded row's
/// timestamp is read from `updated_at`, and the Outcome's history is the
/// time-ordered chain of terminated Action rows.
///
/// `actions` is the only next-action grain. The server-side backfill (Alembic
/// 0028) gave one `current` Action to each Outcome that held a non-blank
/// cursor **at the moment that migration ran** — it is a one-time pass, not
/// ongoing reconciliation, so an Outcome with a blank cursor got none and
/// renders Actionless until re-clarified. It mints a deterministic uuid5 id
/// from the Outcome id (see `backfillActionIdFor`, ADR-0019) so no version
/// skew can duplicate a row. The `todos.next_action_text` cursor it read from
/// no longer exists (ADR-0024).
///
/// The `(outcome_id, role)` index is declared rather than left to the query
/// planner: the "has a current Action" `EXISTS` predicate behind the Next List
/// and the re-clarification queue (ADR-0001 story 3) runs once per candidate
/// Outcome on every re-emission, and without the index that is a full scan of
/// `actions` per candidate. It used to be installed by the storage engine on the
/// engine's own backing table; a Drift-owned store has to declare it.
@TableIndex(name: 'idx_actions_outcome_role', columns: {#outcomeId, #role})
class Actions extends Table {
  TextColumn get id => text().clientDefault(() => uuid.v4())();
  TextColumn get outcomeId =>
      text().references(Todos, #id, onDelete: KeyAction.cascade)();
  TextColumn get userId => text()();

  /// The Action text. Named `text` to match the backend column, but the getter
  /// is `actionText` because a getter literally named `text` would clash with
  /// Drift's `text()` column builder.
  TextColumn get actionText => text().named('text')();

  /// `planned` | `current` | `done` | `superseded`. The CHECK lives here (the
  /// Drift column), mirroring [Todos.intent]; the backend has no Postgres CHECK.
  TextColumn get role => text().customConstraint(
        "NOT NULL CHECK (\"role\" IN ('planned','current','done','superseded'))",
      )();

  /// Planned-queue order; NULL for non-planned roles.
  IntColumn get position => integer().nullable()();

  /// Per-action metadata: low | medium | high (nullable).
  TextColumn get energyLevel => text().nullable()();

  /// Estimated effort in minutes (nullable).
  IntColumn get timeEstimate => integer().nullable()();

  DateTimeColumn get createdAt => dateTime()();

  /// Client-stamped; a superseded row's timestamp is read from here (ADR-0018).
  DateTimeColumn get updatedAt => dateTime().nullable()();

  /// Completion timestamp; non-null once the Action is `done`.
  DateTimeColumn get doneAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
