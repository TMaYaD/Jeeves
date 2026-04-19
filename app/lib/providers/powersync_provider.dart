// PowerSync database provider — the single process-wide owner of the
// on-device sync engine.
//
// Replaces the older `SyncService` singleton.  The provider pattern
// follows the powersync-ja Drift demo: a keepAlive FutureProvider opens
// and initializes `PowerSyncDatabase` once, then watches
// [currentUserIdProvider] to drive `connect()` / `disconnect()`
// reactively — login starts sync, logout stops it.  The Drift
// [databaseProvider] reads this future via `DatabaseConnection.delayed`
// so Drift queries issued before the DB is ready are queued and flushed
// on completion.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart' as ps;
import 'package:sqlite_async/sqlite_async.dart' as sa;

import '../database/powersync_schema.dart';
import '../services/api_service.dart';
import '../services/backend_connector.dart';
import 'auth_provider.dart';

/// Process-wide [PowerSyncDatabase] handle.
///
/// Created once on first read and kept alive for the app's lifetime via
/// [ProviderRef.keepAlive].  Login/logout transitions are observed
/// through [currentUserIdProvider] and translated into
/// `PowerSyncDatabase.connect()` / `.disconnect()` calls on the same
/// instance — the database is never re-opened.
final powerSyncInstanceProvider =
    FutureProvider<ps.PowerSyncDatabase>((ref) async {
  ref.keepAlive();

  final dbFolder = await getApplicationDocumentsDirectory();
  final dbPath = p.join(dbFolder.path, 'jeeves.sqlite');

  // One-shot cleanup for users upgrading from a pre-PowerSync build:
  // that build wrote real Drift-managed `todos` / `tags` / `todo_tags`
  // tables into this same file.  PowerSync installs *views* with those
  // exact names, which cannot coexist with tables of the same name.
  // Drop the legacy tables (and any rows that hadn't yet replicated to
  // a server that didn't exist at the time) so PowerSync's view
  // creation succeeds.  Intentionally destructive — the alternative
  // was a complex rename-and-copy pipeline that wasn't worth the
  // maintenance cost for this one-time upgrade.  Future schema changes
  // must go through Alembic + PowerSync's additive-column discipline,
  // not data-dropping shortcuts.
  await _dropLegacyDriftTables(dbPath);

  final db = ps.PowerSyncDatabase(schema: powersyncSchema, path: dbPath);
  await db.initialize();

  // Bridge the current auth state to PowerSync's connection lifecycle.
  // [currentUserIdProvider] holds `'local'` when no-one is logged in and
  // the real user id otherwise.  Transitions drive connect/disconnect.
  //
  // All transitions are serialized through [pending] so a rapid
  // login → logout (or vice-versa) can never interleave connect() and
  // disconnect() calls on the same PowerSync DB.
  Future<void> pending = Future.value();
  Future<void> applyUser(String userId) {
    final next = pending.then((_) async {
      if (userId == 'local') {
        await db.disconnect();
      } else {
        final connector = JevesBackendConnector(ref.read(apiServiceProvider));
        await db.connect(connector: connector);
      }
    }).catchError((Object e, StackTrace st) {
      // Swallow so one failed transition doesn't poison the chain — errors
      // are observable via PowerSync's status stream.
    });
    pending = next;
    return next;
  }

  await applyUser(ref.read(currentUserIdProvider));
  final sub = ref.listen<String>(
    currentUserIdProvider,
    (previous, next) {
      if (previous == next) return;
      // Enqueue the transition; the serial chain above ensures it runs
      // strictly after any in-flight connect/disconnect completes.
      unawaited(applyUser(next));
    },
  );

  ref.onDispose(sub.close);
  ref.onDispose(db.close);

  return db;
});

Future<void> _dropLegacyDriftTables(String dbPath) async {
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
