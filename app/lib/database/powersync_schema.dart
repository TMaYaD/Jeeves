// PowerSync schema — mirrors the three Drift tables that are replicated.
//
// Column names must match the PostgreSQL column names (snake_case) because
// PowerSync receives rows directly from Postgres via logical replication.
// The id column is managed by PowerSync and must not be listed here.

import 'package:powersync/powersync.dart' as ps;

const powersyncSchema = ps.Schema([
  ps.Table('todos', [
    ps.Column.text('title'),
    ps.Column.text('notes'),
    ps.Column.integer('completed'),
    ps.Column.integer('priority'),
    ps.Column.text('due_date'),
    ps.Column.text('created_at'),
    ps.Column.text('updated_at'),
    ps.Column.text('state'),
    ps.Column.integer('time_estimate'),
    ps.Column.text('energy_level'),
    ps.Column.text('capture_source'),
    ps.Column.text('location_id'),
    ps.Column.text('user_id'),
    ps.Column.text('in_progress_since'),
    ps.Column.integer('time_spent_minutes'),
    ps.Column.text('blocked_by_todo_id'),
    ps.Column.integer('selected_for_today'),
    ps.Column.text('daily_selection_date'),
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
  ]),
]);
