import 'package:drift/drift.dart';
import 'package:drift_sqlite_async/drift_sqlite_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import 'powersync_provider.dart';

/// Shared singleton [GtdDatabase] — kept alive for the app's lifetime.
///
/// Production storage is the same `SqliteConnection` that
/// [powerSyncInstanceProvider] owns, so Drift and PowerSync share a
/// single on-disk SQLite file.  Because the PowerSync database opens
/// asynchronously, the Drift executor is wrapped in
/// [DatabaseConnection.delayed]: any query issued before the underlying
/// future resolves is queued and flushed once it does.  Tests override
/// this with [GtdDatabase.forTesting] + an in-memory executor.
final databaseProvider = Provider<GtdDatabase>((ref) {
  final connection = DatabaseConnection.delayed(Future(() async {
    final psDb = await ref.read(powerSyncInstanceProvider.future);
    return SqliteAsyncDriftConnection(psDb);
  }));
  final db = GtdDatabase.forTesting(connection);
  ref.onDispose(db.close);
  return db;
});
