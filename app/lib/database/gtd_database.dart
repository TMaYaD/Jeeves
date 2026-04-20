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

import 'daos/inbox_dao.dart';
import 'daos/tag_dao.dart';
import 'daos/todo_dao.dart';
import 'tables.dart';

export 'tables.dart';

part 'gtd_database.g.dart';

@DriftDatabase(
  tables: [Todos, Tags, TodoTags],
  daos: [InboxDao, TagDao, TodoDao],
)
class GtdDatabase extends _$GtdDatabase {
  GtdDatabase(super.executor);

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await _addColumnIfTable(m, todos, todos.inProgressSince);
            await _addColumnIfTable(m, todos, todos.timeSpentMinutes);
            await _addColumnIfTable(m, todos, todos.blockedByTodoId);
          }
          if (from < 3) {
            await _addColumnIfTable(m, todos, todos.selectedForToday);
            await _addColumnIfTable(m, todos, todos.dailySelectionDate);
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
    await m.addColumn(table, column);
  }
}
