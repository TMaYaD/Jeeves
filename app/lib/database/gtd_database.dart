/// Local-first GTD database backed by Drift.
///
/// In production the underlying storage is PowerSync's `SqliteConnection`
/// (shared so replicated rows are visible to Drift immediately via SQLite's
/// update_hook).  In tests the constructor takes an injected [QueryExecutor]
/// (typically `NativeDatabase.memory()`) which keeps every DAO test hermetic
/// and synchronous.
///
/// Schema ownership: PowerSync creates the application-visible tables as
/// views over its internal storage, so Drift's [migration] is effectively
/// a no-op on the production path.  On the in-memory test path [onCreate]
/// and [onUpgrade] run normally.
library;

import 'package:drift/drift.dart';
import 'package:drift_sqlite_async/drift_sqlite_async.dart';
import 'package:powersync/powersync.dart' show uuid;
import 'package:sqlite_async/sqlite_async.dart';

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
  /// Production constructor — wraps a [SqliteConnection] owned by PowerSync.
  GtdDatabase(SqliteConnection db) : super(SqliteAsyncDriftConnection(db));

  /// Test constructor — accepts an injected [QueryExecutor] (e.g. in-memory).
  GtdDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(todos, todos.inProgressSince);
            await m.addColumn(todos, todos.timeSpentMinutes);
            await m.addColumn(todos, todos.blockedByTodoId);
          }
          if (from < 3) {
            await m.addColumn(todos, todos.selectedForToday);
            await m.addColumn(todos, todos.dailySelectionDate);
          }
        },
      );
}
