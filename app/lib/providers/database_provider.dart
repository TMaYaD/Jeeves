import 'package:drift/drift.dart';
import 'package:drift_sqlite_async/drift_sqlite_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../services/sync_service.dart';

/// Shared singleton [GtdDatabase] — kept alive for the app's lifetime.
///
/// On the production path the underlying [QueryExecutor] is a
/// [SqliteAsyncDriftConnection] wrapping the same `SqliteConnection` that
/// PowerSync owns.  Because `SyncService.start()` runs asynchronously after
/// authentication, the connection may not yet be available when this
/// provider is first read — so it's wrapped in [DatabaseConnection.delayed]
/// and backed by [SyncService.whenReady], which completes as soon as the
/// PowerSync database has been initialized.  Any Drift query issued before
/// that point (there shouldn't be any — auth screens don't hit the DB) is
/// queued and flushed on connection.
///
/// Override with [GtdDatabase.forTesting] in tests.
final databaseProvider = Provider<GtdDatabase>((ref) {
  final connection = DatabaseConnection.delayed(_openConnection());
  final db = GtdDatabase.forTesting(connection);
  ref.onDispose(db.close);
  return db;
});

Future<DatabaseConnection> _openConnection() async {
  final psDb = await SyncService.instance.whenReady;
  return SqliteAsyncDriftConnection(psDb);
}
