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

  /// Timestamp of the last time a person-tag was assigned to or removed from this todo.
  /// Set by the server/client whenever a TodoTag with type='person' is created or deleted.
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

  /// Per-task disposition chosen during session review.
  /// NULL = not yet reviewed (active session) or done task.
  /// 'rollover' = carry forward to next session's pre-selected list.
  /// 'leave' = return to Next Actions (no mutation on todos).
  /// 'maybe' = defer; FocusSessionReviewNotifier writes intent='maybe' to todos.
  TextColumn get disposition => text().nullable()();

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
