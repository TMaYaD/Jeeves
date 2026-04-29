/// Drift table declarations for the local GTD database.
///
/// These mirror the backend PostgreSQL schema so PowerSync can replicate
/// rows bidirectionally without column-name mismatches.
library;

import 'package:drift/drift.dart';
import 'package:powersync/powersync.dart' show uuid;

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

  /// Who or what a `waiting_for`-state task is waiting on (freeform).
  TextColumn get waitingFor => text().nullable()();

  /// Cumulative time spent in minutes across all focus stints.
  IntColumn get timeSpentMinutes =>
      integer().withDefault(const Constant(0)).clientDefault(() => 0)();

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
class TimeLogs extends Table {
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

class Tags extends Table {
  TextColumn get id => text().clientDefault(() => uuid.v4())();
  TextColumn get name => text().withLength(max: 100)();
  TextColumn get color => text().nullable()();

  /// GTD discriminator: context | project | area | label
  TextColumn get type => text()
      .withDefault(const Constant('context'))
      .clientDefault(() => 'context')();

  TextColumn get userId => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// todo_tags  (junction)
// ---------------------------------------------------------------------------

class TodoTags extends Table {
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
