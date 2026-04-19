/// Local-first GTD database backed by Drift.
///
/// Accepts any Drift [QueryExecutor] so the same class serves both
/// production (a `SqliteAsyncDriftConnection` over PowerSync's shared
/// SQLite file, typically wrapped in `DatabaseConnection.delayed`) and
/// tests (`NativeDatabase.memory()`).
///
/// Schema ownership: PowerSync creates the application-visible tables as
/// views over its internal storage, so Drift's [migration] is effectively
/// a no-op on the production path.  On the in-memory test path [onCreate]
/// and [onUpgrade] run normally.
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
  int get schemaVersion => 4;

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
          if (from < 4) {
            await m.addColumn(todos, todos.waitingFor);
          }
        },
      );
}
