/// Local-first GTD database backed by Drift.
///
/// Accepts any Drift [QueryExecutor] so the same class serves both
/// production (a `SqliteAsyncDriftConnection` over PowerSync's shared
/// SQLite file, typically wrapped in `DatabaseConnection.delayed`) and
/// tests (`NativeDatabase.memory()`).
///
/// Schema ownership: on production PowerSync owns the application-visible
/// `todos` / `tags` / `todo_tags` as views over its internal `ps_data__*`
/// tables, so schema changes there are driven by [powersyncSchema], not by
/// Drift's migrator — `ALTER TABLE` on a view throws SQLITE_ERROR.  The
/// [_addColumnIfTable] helper short-circuits `addColumn` when the target is
/// a view so upgrades are a true no-op on the production path while still
/// running against real tables under `NativeDatabase.memory()` in tests.
library;

import 'package:drift/drift.dart';
import 'package:powersync/powersync.dart' show uuid;

import 'daos/focus_session_dao.dart';
import 'daos/inbox_dao.dart';
import 'daos/search_dao.dart';
import 'daos/tag_dao.dart';
import 'daos/time_log_dao.dart';
import 'daos/todo_dao.dart';
import 'tables.dart';

export 'tables.dart';

part 'gtd_database.g.dart';

@DriftDatabase(
  tables: [Todos, Tags, TodoTags, TimeLogs, FocusSessions, FocusSessionTasks],
  daos: [InboxDao, TagDao, TodoDao, TimeLogDao, FocusSessionDao],
)
class GtdDatabase extends _$GtdDatabase {
  GtdDatabase(super.executor);

  /// Plain-class DAO for universal search (no code generation required).
  late final SearchDao searchDao = SearchDao(this);

  @override
  int get schemaVersion => 15;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await _addColumnIfTable(m, todos, todos.timeSpentMinutes);
            // in_progress_since existed from v2 to v13; add it here so the
            // v1→v14 upgrade path is consistent, then drop it in the v14 step.
            final todosInfo = await customSelect(
              "SELECT type FROM sqlite_master WHERE name = 'todos'",
            ).get();
            if (todosInfo.isNotEmpty &&
                todosInfo.first.read<String>('type') == 'table') {
              await customStatement(
                'ALTER TABLE todos ADD COLUMN in_progress_since TEXT',
              );
              // blocked_by_todo_id existed from v2 to v7.
              await customStatement(
                'ALTER TABLE todos ADD COLUMN blocked_by_todo_id TEXT',
              );
            }
          }
          if (from < 3) {
            // selected_for_today and daily_selection_date existed v3–v13.
            final todosInfo = await customSelect(
              "SELECT type FROM sqlite_master WHERE name = 'todos'",
            ).get();
            if (todosInfo.isNotEmpty &&
                todosInfo.first.read<String>('type') == 'table') {
              await customStatement(
                'ALTER TABLE todos ADD COLUMN selected_for_today INTEGER',
              );
              await customStatement(
                'ALTER TABLE todos ADD COLUMN daily_selection_date TEXT',
              );
            }
          }
          if (from < 4) {
            await _addColumnIfTable(m, todos, todos.waitingFor);
          }
          if (from < 5) {
            await _addColumnIfTable(m, todoTags, todoTags.userId);
          }
          if (from < 6) {
            // todoTags.id is declared non-nullable, so m.addColumn generates
            // ALTER TABLE ... ADD COLUMN id TEXT NOT NULL, which SQLite rejects
            // on populated tables (no DEFAULT clause).  Add as nullable first,
            // backfill, then the invariant is satisfied without a table rebuild.
            // _addColumnIfTable is not used here because it delegates to
            // m.addColumn which would emit the NOT NULL form.
            final rows = await customSelect(
              "SELECT type FROM sqlite_master WHERE name = 'todo_tags'",
            ).get();
            if (rows.isNotEmpty && rows.first.read<String>('type') == 'table') {
              await customStatement('ALTER TABLE todo_tags ADD COLUMN id TEXT');
              await customStatement(
                "UPDATE todo_tags SET id = lower(hex(randomblob(16))) "
                "WHERE id IS NULL",
              );
            }
          }
          if (from < 7) {
            // Backfill derived colors for tags created before per-tag color
            // storage was introduced.  Running this as a migration rather than
            // on every startup means a later updateColor(tagId, null) that
            // intentionally clears a color is never overwritten.
            await tagDao.backfillAllMissingColors();
          }
          if (from < 8) {
            final rows = await customSelect(
              "SELECT type FROM sqlite_master WHERE name = 'todos'",
            ).get();
            if (rows.isNotEmpty && rows.first.read<String>('type') == 'table') {
              final cols =
                  await customSelect('PRAGMA table_info(todos)').get();
              final hasCol = cols.any(
                (r) => r.read<String>('name') == 'blocked_by_todo_id',
              );
              if (hasCol) {
                await customStatement(
                  'ALTER TABLE todos DROP COLUMN blocked_by_todo_id',
                );
              }
            }
          }
          if (from < 9) {
            final rows = await customSelect(
              "SELECT type FROM sqlite_master WHERE name = 'time_logs'",
            ).get();
            // Only create the real table when it doesn't exist yet.
            // On production PowerSync will have already created a view named
            // 'time_logs' from powersyncSchema — calling createTable on a
            // view would fail.  When rows is empty the object doesn't exist
            // at all (NativeDatabase test path), so we create it.
            if (rows.isEmpty) {
              await m.createTable(timeLogs);
            }
          }
          if (from < 10) {
            final todosInfo = await customSelect(
              "SELECT type FROM sqlite_master WHERE name = 'todos'",
            ).get();
            if (todosInfo.isNotEmpty &&
                todosInfo.first.read<String>('type') == 'table') {
              final cols =
                  await customSelect('PRAGMA table_info(todos)').get();
              final hasIntent =
                  cols.any((r) => r.read<String>('name') == 'intent');
              if (!hasIntent) {
                await customStatement(
                  "ALTER TABLE todos ADD COLUMN intent TEXT NOT NULL DEFAULT 'next'",
                );
              }
              final hasStateV10 =
                  cols.any((r) => r.read<String>('name') == 'state');
              if (hasStateV10) {
                await customStatement(
                  "UPDATE todos SET intent = 'maybe', state = 'next_action' "
                  "WHERE state = 'someday_maybe'",
                );
              }
            }
          }
          if (from < 11) {
            // Guard: only ADD COLUMN if todos table exists and clarified column doesn't.
            final tables = await customSelect(
              "SELECT name FROM sqlite_master WHERE type='table' AND name='todos'",
            ).get();
            if (tables.isNotEmpty) {
              final cols = await customSelect("PRAGMA table_info(todos)").get();
              final hasClarified =
                  cols.any((r) => r.read<String>('name') == 'clarified');
              if (!hasClarified) {
                await customStatement(
                  "ALTER TABLE todos ADD COLUMN clarified INTEGER NOT NULL DEFAULT 1",
                );
              }
              // Normalize legacy inbox rows (state column exists until v15).
              final hasStateV11 =
                  cols.any((r) => r.read<String>('name') == 'state');
              if (hasStateV11) {
                await customStatement(
                  "UPDATE todos SET clarified = 0, state = 'next_action' WHERE state = 'inbox'",
                );
              }
            }
          }
          if (from < 12) {
            final tables = await customSelect(
              "SELECT name FROM sqlite_master WHERE type='table' AND name='todos'",
            ).get();
            if (tables.isNotEmpty) {
              final cols = await customSelect("PRAGMA table_info(todos)").get();
              final hasDoneAt =
                  cols.any((r) => r.read<String>('name') == 'done_at');
              if (!hasDoneAt) {
                await customStatement(
                  'ALTER TABLE todos ADD COLUMN done_at TEXT',
                );
              }
              // Backfill done_at only for rows where it is not already set.
              // Mirror the Postgres backfill: also cover rows where completed=1
              // but state diverged (nothing enforced co-setting of both fields).
              final hasStateV12 =
                  cols.any((r) => r.read<String>('name') == 'state');
              final hasCompleted =
                  cols.any((r) => r.read<String>('name') == 'completed');
              if (hasStateV12) {
                if (hasCompleted) {
                  await customStatement(
                    "UPDATE todos "
                    "SET done_at = COALESCE(done_at, updated_at) "
                    "WHERE (state = 'done' OR completed = 1) AND done_at IS NULL",
                  );
                } else {
                  await customStatement(
                    "UPDATE todos "
                    "SET done_at = COALESCE(done_at, updated_at) "
                    "WHERE state = 'done' AND done_at IS NULL",
                  );
                }
                await customStatement(
                  "UPDATE todos SET state = 'next_action' WHERE state = 'done'",
                );
              } else if (hasCompleted) {
                await customStatement(
                  "UPDATE todos "
                  "SET done_at = COALESCE(done_at, updated_at) "
                  "WHERE completed = 1 AND done_at IS NULL",
                );
              }
              // completed column: intentionally NOT dropped — SQLite DROP COLUMN
              // is unreliable across OS versions; Drift treats it as invisible.
            }
          }
          if (from < 13) {
            // Collapse legacy waiting_for state rows before PowerSync re-syncs
            // the rewritten rows from Postgres (state column dropped in v15).
            final v13Cols =
                await customSelect('PRAGMA table_info(todos)').get();
            if (v13Cols.any((r) => r.read<String>('name') == 'state')) {
              await customStatement(
                "UPDATE todos SET state = 'next_action' WHERE state = 'waiting_for'",
              );
            }
          }
          if (from < 14) {
            // Create FocusSessions/FocusSessionTasks tables in test only;
            // PowerSync creates views from powersyncSchema in production.
            final fsRows = await customSelect(
              "SELECT type FROM sqlite_master WHERE name = 'focus_sessions'",
            ).get();
            if (fsRows.isEmpty) {
              await m.createTable(focusSessions);
            }
            final fstRows = await customSelect(
              "SELECT type FROM sqlite_master WHERE name = 'focus_session_tasks'",
            ).get();
            if (fstRows.isEmpty) {
              await m.createTable(focusSessionTasks);
            }

            // Add focus_session_id to time_logs (no-op on production view).
            await _addColumnIfTable(m, timeLogs, timeLogs.focusSessionId);

            // Drop retired columns from todos (no-op on production view).
            await _dropColumnIfTable('todos', 'in_progress_since');
            await _dropColumnIfTable('todos', 'selected_for_today');
            await _dropColumnIfTable('todos', 'daily_selection_date');

            // Collapse in_progress → next_action (state column dropped in v15).
            final v14Cols =
                await customSelect('PRAGMA table_info(todos)').get();
            if (v14Cols.any((r) => r.read<String>('name') == 'state')) {
              await customStatement(
                "UPDATE todos SET state = 'next_action' WHERE state = 'in_progress'",
              );
            }
          }
          if (from < 15) {
            // Drop the now-constant state column (all rows hold 'next_action').
            await _dropColumnIfTable('todos', 'state');
          }
        },
      );

  /// Runs [Migrator.addColumn] only when [table] is a real SQLite table.
  ///
  /// On production `todos` / `tags` / `todo_tags` are PowerSync-managed views
  /// (see [powersyncSchema]); `ALTER TABLE <view> ADD COLUMN` raises
  /// `SqliteException(1): Cannot add a column to a view`.  PowerSync already
  /// mirrors every Drift-declared column on its view, so skipping the ALTER
  /// is functionally equivalent.  Under `NativeDatabase.memory()` in tests
  /// the target is a real table and the migration runs normally.
  Future<void> _addColumnIfTable(
      Migrator m, TableInfo<Table, dynamic> table, GeneratedColumn column) async {
    final rows = await customSelect(
      "SELECT type FROM sqlite_master WHERE name = ?",
      variables: [Variable<String>(table.actualTableName)],
    ).get();
    if (rows.isEmpty) return; // Unknown object; don't guess.
    if (rows.first.read<String>('type') != 'table') return;
    final cols =
        await customSelect('PRAGMA table_info(${table.actualTableName})').get();
    if (cols.any((r) => r.read<String>('name') == column.name)) return;
    await m.addColumn(table, column);
  }

  /// Drops [columnName] from [tableName] only when the target is a real SQLite
  /// table (not a PowerSync view). Checks column existence before dropping to
  /// make the operation idempotent.
  Future<void> _dropColumnIfTable(String tableName, String columnName) async {
    final rows = await customSelect(
      "SELECT type FROM sqlite_master WHERE name = ?",
      variables: [Variable<String>(tableName)],
    ).get();
    if (rows.isEmpty || rows.first.read<String>('type') != 'table') return;
    final cols = await customSelect('PRAGMA table_info($tableName)').get();
    if (!cols.any((r) => r.read<String>('name') == columnName)) return;
    await customStatement('ALTER TABLE $tableName DROP COLUMN $columnName');
  }
}
