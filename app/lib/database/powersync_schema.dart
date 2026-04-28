// PowerSync schema — mirrors the tables that are replicated.
//
// Column names must match the PostgreSQL column names (snake_case) because
// PowerSync receives rows directly from Postgres via logical replication.
//
// The implicit primary-key `id` column is managed by PowerSync for every
// table and must NOT be listed here — including on todo_tags (replicated
// via a per-user parameter bucket thanks to the denormalized `user_id`
// column added in Alembic 0008; see infra/powersync/sync-config.yaml).
//
// focus_session_tasks has no `user_id` column; its sync bucket JOINs through
// focus_sessions to apply the per-user filter (see sync-config.yaml).

import 'package:powersync/powersync.dart' as ps;

const powersyncSchema = ps.Schema([
  ps.Table('todos', [
    ps.Column.text('title'),
    ps.Column.text('notes'),
    ps.Column.integer('priority'),
    ps.Column.text('due_date'),
    ps.Column.text('created_at'),
    ps.Column.text('updated_at'),
    ps.Column.text('intent'),
    ps.Column.integer('clarified'),
    ps.Column.text('done_at'),
    ps.Column.integer('time_estimate'),
    ps.Column.text('energy_level'),
    ps.Column.text('capture_source'),
    ps.Column.text('location_id'),
    ps.Column.text('user_id'),
    // Previously client-only; now replicated (see Alembic 0007).
    ps.Column.text('waiting_for'),
    ps.Column.integer('time_spent_minutes'),
  ]),
  ps.Table('time_logs', [
    ps.Column.text('user_id'),
    ps.Column.text('task_id'),
    ps.Column.text('started_at'),
    ps.Column.text('ended_at'),
    ps.Column.text('focus_session_id'),
  ]),
  ps.Table('focus_sessions', [
    ps.Column.text('user_id'),
    ps.Column.text('started_at'),
    ps.Column.text('ended_at'),
    ps.Column.text('current_task_id'),
  ]),
  ps.Table('focus_session_tasks', [
    ps.Column.text('focus_session_id'),
    ps.Column.text('task_id'),
    ps.Column.integer('position'),
    ps.Column.text('disposition'),
  ]),
  ps.Table('tags', [
    ps.Column.text('name'),
    ps.Column.text('color'),
    ps.Column.text('type'),
    ps.Column.text('user_id'),
  ]),
  ps.Table('todo_tags', [
    ps.Column.text('todo_id'),
    ps.Column.text('tag_id'),
    ps.Column.text('user_id'),
  ]),
]);
