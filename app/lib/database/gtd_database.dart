/// Local-first GTD database backed by Drift (SQLite).
///
/// [schemaVersion] is 1 — this is a clean-slate schema; no prior Drift
/// migrations exist. All subsequent schema changes must use Migrator.addColumn /
/// Migrator.createTable inside [onUpgrade] following additive-only discipline.
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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
  /// Production constructor — opens (or creates) the on-device SQLite file.
  GtdDatabase() : super(_openConnection());

  /// Test constructor — accepts an injected [QueryExecutor] (e.g. in-memory).
  GtdDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        // onUpgrade: use m.addColumn / m.createTable for future versions.
      );
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'jeeves.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
