// PowerSync schema — mirrors the three tables that are replicated.
//
// Column names must match the PostgreSQL column names (snake_case) because
// PowerSync receives rows directly from Postgres via logical replication.
//
// The implicit primary-key id columns for todos and tags are managed by
// PowerSync and must NOT be listed here.  todo_tags.id is an intentional
// exception: it is an explicit UUID column (not the composite PK) stored so
// the upload handler can locate rows for deletion by entry.id.

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
  ]),
  ps.Table('tags', [
    ps.Column.text('name'),
    ps.Column.text('color'),
    ps.Column.text('type'),
    ps.Column.text('user_id'),
  ]),
  ps.Table('todo_tags', [
    ps.Column.text('id'),
    ps.Column.text('todo_id'),
    ps.Column.text('tag_id'),
  ]),
]);
