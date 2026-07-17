/// Drift table declarations for the local GTD database.
///
/// These mirror the backend PostgreSQL schema so PowerSync can replicate
/// rows bidirectionally without column-name mismatches.
library;

import 'package:drift/drift.dart';
import 'package:powersync/powersync.dart' show uuid;

/// Marks a Drift table as replicated via PowerSync.
/// The powersync_schema_builder reads this marker to decide which tables
/// to include in the generated powersync_schema.g.dart.
mixin Synced on Table {}

// ---------------------------------------------------------------------------
// todos
// ---------------------------------------------------------------------------

class Todos extends Table with Synced {
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
  ///   - Outcome completion or trashing (and the reverse: restore, clearDoneAt)
  ///
  /// Non-stamping writes include current-Action completion (engagement, not
  /// clarification), TimeLog writes, and Area / Label changes (organising).
  /// Drives the re-clarification ("Stale") predicate; see todo_dao.dart's
  /// _needsReviewWhere.
  DateTimeColumn get lastClarifiedAt => dateTime().nullable()();

  /// Cumulative time spent in minutes across all focus stints.
  IntColumn get timeSpentMinutes =>
      integer().withDefault(const Constant(0)).clientDefault(() => 0)();

  /// The current next-action text for this task. NULL = no next action defined (Actionless).
  /// Set when a task is processed through inbox-clarify or the review step.
  TextColumn get nextActionText => text().withLength(max: 500).nullable()();

  /// When a focus session last closed with this task non-done.
  /// Stamped by reviewAndCloseSession. Used to detect staleness vs lastClarifiedAt.
  DateTimeColumn get lastNextActionCompletionAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// time_logs
// ---------------------------------------------------------------------------

/// One row per focus stint on a task. PowerSync manages `id`.
///
/// Timestamps are ISO-8601 UTC text strings.
/// `ended_at` is null while the stint is still running.
class TimeLogs extends Table with Synced {
  /// PowerSync-managed primary key — no clientDefault.
  TextColumn get id => text()();
  TextColumn get userId => text()();
  TextColumn get taskId => text().references(Todos, #id)();

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
class FocusSessions extends Table with Synced {
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
class FocusSessionTasks extends Table with Synced {
  /// PowerSync sync row identifier — not the domain key.
  TextColumn get id => text().unique().clientDefault(() => uuid.v4())();
  TextColumn get focusSessionId => text().references(FocusSessions, #id)();
  TextColumn get taskId => text().references(Todos, #id)();
  IntColumn get position => integer()();

  /// Per-task disposition chosen during session review, for **Plan members**.
  /// Off-Plan engaged Outcomes have no row here (the Plan never auto-grows —
  /// ADR-0002); their Dispositions live in [FocusSessionDispositions] instead
  /// (ADR-0015).
  /// NULL = not yet reviewed (active session) or done task.
  /// 'rollover' = carry forward to next session's pre-selected list.
  /// 'leave' = return to Next Actions (no mutation on todos).
  /// 'maybe' = defer; FocusSessionReviewNotifier writes intent='maybe' to todos.
  TextColumn get disposition => text().nullable()();

  /// Denormalized from `focus_sessions.user_id` so PowerSync can filter
  /// junction rows with a per-user parameter bucket (see Alembic 0025 and
  /// sync-config.yaml).
  TextColumn get userId => text()();

  @override
  Set<Column<Object>> get primaryKey => {focusSessionId, taskId};
}

// ---------------------------------------------------------------------------
// focus_session_dispositions
// ---------------------------------------------------------------------------

/// Durable home for Review-phase Dispositions on **off-Plan engaged** Outcomes
/// (ADR-0015).
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
class FocusSessionDispositions extends Table with Synced {
  /// PowerSync sync row identifier — not the domain key. Derive it
  /// deterministically via `focusSessionDispositionIdFor(sessionId, taskId)`
  /// (see focus_session_dao.dart) so re-recording the same pair collapses under
  /// INSERT OR REPLACE instead of accumulating duplicate rows.
  TextColumn get id => text().unique().clientDefault(() => uuid.v4())();
  TextColumn get focusSessionId => text().references(FocusSessions, #id)();
  TextColumn get taskId => text().references(Todos, #id)();

  /// Per-(FocusSession, Outcome) disposition: 'rollover' | 'leave' | 'maybe'.
  /// Same vocabulary as [FocusSessionTasks.disposition]. NULL is unused here —
  /// a row exists only once the user has dispositioned the off-Plan Outcome.
  TextColumn get disposition => text().nullable()();

  /// Denormalized from `focus_sessions.user_id` so PowerSync can filter
  /// junction rows with a per-user parameter bucket (see Alembic 0027 and
  /// sync-config.yaml).
  TextColumn get userId => text()();

  @override
  Set<Column<Object>> get primaryKey => {focusSessionId, taskId};
}

// ---------------------------------------------------------------------------
// tags
// ---------------------------------------------------------------------------

class Tags extends Table with Synced {
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
  /// Drift emits `UNIQUE (name, type)` in the test DB's `CREATE TABLE`, so any
  /// regression that mints a second row with the same `(name, type)` fails
  /// the suite loudly. In production `tags` is a PowerSync-managed view over
  /// `ps_data__tags`; `uniqueKeys` does not propagate to the backing table, so
  /// production behaviour is unchanged — the invariant is enforced at the
  /// application layer via `TagDao.findOrCreateTag` and a one-time
  /// `dedupeTags` pass on startup.
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
class UserPreferences extends Table with Synced {
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
// sync_dead_letters  (local-only diagnostics)
// ---------------------------------------------------------------------------

/// Dead Letter: a durable record of a CRUD-queue upload that failed with a
/// non-retryable status (see `JevesBackendConnector.classifyUploadError`).
///
/// Deliberately **not** `with Synced` — this is a plain local SQLite table,
/// excluded from the PowerSync schema, never replicated. It is developer
/// telemetry for root-cause diagnosis (which operation × table × status
/// combinations fail in the wild), not a user-facing retry queue; the goal
/// is for it to trend toward empty as root causes are fixed.
class SyncDeadLetters extends Table {
  /// Auto-incrementing insertion order — pruning tie-breaker. Pruning itself
  /// orders by [createdAt] (last occurrence), so a repeatedly-refreshed
  /// failure outlives newer one-offs regardless of its original insertion.
  IntColumn get id => integer().autoIncrement()();

  /// The synced table the failed entry targeted (e.g. 'todos').
  /// Named explicitly: `tableName` collides with Drift's `Table.tableName`.
  TextColumn get targetTable => text().named('table_name')();

  /// The CRUD operation: PUT | PATCH | DELETE.
  TextColumn get op => text()();

  /// The id of the row the entry targeted.
  TextColumn get rowId => text()();

  /// JSON-encoded `opData` of the failed entry; null for deletes.
  TextColumn get opData => text().nullable()();

  /// HTTP status the backend returned.
  IntColumn get statusCode => integer()();

  /// Error response body, truncated by the connector before recording.
  TextColumn get responseBody => text().nullable()();

  /// When this failure was last recorded — refreshed when the same failure
  /// repeats (see [uniqueKeys]).
  DateTimeColumn get createdAt => dateTime().clientDefault(DateTime.now)();

  /// One row per distinct failure: a batch retried after a partial failure
  /// re-uploads entries that were already dead-lettered, and the repeat
  /// occurrence must refresh the existing row, not accumulate duplicates.
  /// `GtdDatabase.recordSyncDeadLetter` upserts against this key.
  @override
  List<Set<Column<Object>>> get uniqueKeys => [
        {targetTable, rowId, op, statusCode},
      ];
}

// ---------------------------------------------------------------------------
// todo_tags  (junction)
// ---------------------------------------------------------------------------

class TodoTags extends Table with Synced {
  /// PowerSync exposes `todo_tags` as a view over `ps_data__todo_tags` whose
  /// INSTEAD OF INSERT trigger writes `NEW.id` into the backing table — so
  /// an explicit `id` is required even though the *logical* identity of a
  /// junction row is (todo_id, tag_id).  Callers should derive it
  /// deterministically via `todoTagIdFor(todoId, tagId)` (see tag_dao.dart)
  /// so re-assigning the same tag collapses under INSERT OR REPLACE instead
  /// of accumulating duplicate rows.
  TextColumn get id => text().unique()();

  TextColumn get todoId => text().references(Todos, #id)();
  TextColumn get tagId => text().references(Tags, #id)();

  /// Denormalized from `todos.user_id` so PowerSync can filter junction rows
  /// with a per-user parameter bucket (see Alembic 0008 and sync-config.yaml).
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
class Captures extends Table with Synced {
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
class CaptureOutcomes extends Table with Synced {
  /// PowerSync sync row identifier — not the domain key. Derive it
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

  /// Denormalized from the parent's `user_id` so PowerSync can filter junction
  /// rows with a per-user parameter bucket (see Alembic 0026 and
  /// sync-config.yaml).
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
class CaptureTags extends Table with Synced {
  /// PowerSync sync row identifier — derive it deterministically via
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
