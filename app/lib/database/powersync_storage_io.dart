// Native PowerSync storage adapter (Android, iOS, macOS, Linux, Windows).
//
// Selected by the conditional export in powersync_storage.dart when
// dart:io is available.  All dart:io and path_provider usage is confined
// here so the rest of the codebase compiles cleanly on web.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart' as ps;
import 'package:sqlite_async/sqlite_async.dart' as sa;

class PowerSyncStorageImpl {
  Future<ps.PowerSyncDatabase> openDatabase(ps.Schema schema) async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'jeeves.sqlite');

    // One-shot cleanup for users upgrading from a pre-PowerSync build.
    // That build wrote real Drift-managed `todos` / `tags` / `todo_tags`
    // tables into this same file.  PowerSync installs *views* with those
    // exact names, which cannot coexist with tables of the same name.
    await _dropLegacyDriftTables(path);

    final db = ps.PowerSyncDatabase(schema: schema, path: path);
    await db.initialize();
    return db;
  }
}

Future<void> _dropLegacyDriftTables(String dbPath) async {
  // Skip when the file doesn't exist yet — opening a fresh SqliteDatabase
  // would create an empty file, which PowerSync will then treat as its own
  // first-run storage.  Avoiding the stub write keeps cold-start cheap for
  // new installs.
  if (!File(dbPath).existsSync()) return;

  final raw = sa.SqliteDatabase(path: dbPath);
  try {
    await raw.initialize();
    final rows = await raw.getAll(
      "SELECT name FROM sqlite_master "
      "WHERE type = 'table' AND name IN ('todos', 'tags', 'todo_tags')",
    );
    if (rows.isEmpty) return;
    await raw.writeTransaction((tx) async {
      for (final row in rows) {
        await tx.execute('DROP TABLE ${row['name']}');
      }
    });
  } finally {
    await raw.close();
  }
}
