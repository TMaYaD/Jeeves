/// A stand-in for the phone's legacy PowerSync-side store.
///
/// **Cutover tooling — removed by #556.**
///
/// A real SQLite database whose shape is **derived from `powersyncSchema`**
/// rather than hand-copied: same tables, same columns, same column affinities.
/// That matters more than it looks. PowerSync declares `todos.clarified`,
/// `todos.priority` and friends as INTEGER columns, so `getAll` hands the reseed
/// an `int`; a double built out of all-TEXT columns would hand it `'1'` instead,
/// every integer and boolean field would be refused as unencodable, and the suite
/// would be asserting against a store the phone does not have.
///
/// What is deliberately *not* copied from Drift: the NOT NULLs and CHECKs.
/// PowerSync exposes each table as a view over `ps_data__*`, so a row with a NULL
/// `title` is a state the production store can genuinely be in — and it is
/// exactly the state the reseed has to refuse to carry. A Drift-declared schema
/// would make it unrepresentable and the held-back case untestable.
///
/// Reads go through [readRows], the same `InitialUploadRowSource` seam production hands
/// PowerSync's `getAll` to, so the read-only proof in the report is a real
/// observation about a real mutable store here too.
library;

import 'package:jeeves/cutover/converge_verify/canonical_row.dart'
    show convergeVerifyTables;
import 'package:jeeves/sync/initial_upload_plan.dart' show InitialUploadRowSource;
import 'package:jeeves/database/powersync_schema.g.dart';
import 'package:powersync/powersync.dart' as ps;
import 'package:sqlite3/sqlite3.dart';

class ReseedLegacyStore {
  ReseedLegacyStore._(this._db);

  factory ReseedLegacyStore.open() {
    final byName = {
      for (final table in powersyncSchema.tables) table.name: table,
    };
    final db = sqlite3.openInMemory();
    for (final name in convergeVerifyTables) {
      final table = byName[name];
      if (table == null) {
        throw StateError(
          'powersyncSchema has no table "$name" — the reseed walks it, so the '
          'legacy double cannot stand in for it',
        );
      }
      final columns = [
        // `id` is the view's own primary key rather than a declared column.
        '"id" TEXT',
        for (final column in table.columns)
          '"${column.name}" ${column.type.sqlite}',
      ];
      db.execute('CREATE TABLE "$name" (${columns.join(', ')})');
    }
    return ReseedLegacyStore._(db);
  }

  final Database _db;

  /// Every column [table] carries, `id` first — what a seeder asserts against so
  /// a newly synced column cannot go quietly unseeded.
  static List<String> columnsOf(String table) {
    final declared = powersyncSchema.tables
        .firstWhere((candidate) => candidate.name == table);
    return ['id', for (final column in declared.columns) column.name];
  }

  /// Insert one row. Absent columns land as NULL, which is the whole point.
  void insert(String table, Map<String, Object?> values) {
    final columns = values.keys.toList();
    _db.execute(
      'INSERT INTO "$table" (${columns.map((c) => '"$c"').join(', ')}) '
      'VALUES (${List.filled(columns.length, '?').join(', ')})',
      [for (final column in columns) values[column]],
    );
  }

  /// Change one column of one row — the "the user kept using the old stack
  /// between runs" case.
  void update(String table, String id, String column, Object? value) {
    _db.execute(
      'UPDATE "$table" SET "$column" = ? WHERE "id" = ?',
      [value, id],
    );
  }

  /// The `InitialUploadRowSource` seam. Unfiltered, exactly as production reads it.
  InitialUploadRowSource get readRows => (String table) async {
        final result = _db.select('SELECT * FROM "$table"');
        return [for (final row in result) Map<String, Object?>.of(row)];
      };

  void close() => _db.close();
}

/// The declared type of one column, for a test that wants to assert affinities.
ps.ColumnType columnTypeOf(String table, String column) => powersyncSchema.tables
    .firstWhere((candidate) => candidate.name == table)
    .columns
    .firstWhere((candidate) => candidate.name == column)
    .type;
