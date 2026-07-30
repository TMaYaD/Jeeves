// The on-device SQLite store the domain read model lives in.
//
// **PowerSync is the storage engine here and nothing else. It does not
// connect.** #591 flipped the op-log spine on as the production sync path, so
// this provider opens the database and stops. There is no `connect()`, no
// connector, and no `currentUserIdProvider` listener — a signed-in device does
// not replicate to the legacy mirrored Postgres tables.
//
// `ps_crud` grows with nothing draining it, bounded by one user's writes: local
// writes enqueue because the tables are PowerSync-managed, which cannot be
// turned off without the fresh-store swap. The queue costs disk and nothing
// else, and the file goes with the engine.
//
// The Drift [databaseProvider] reads this future via `DatabaseConnection.delayed`
// so Drift queries issued before the DB is ready are queued and flushed on
// completion. Platform-specific storage (file path on native, OPFS on web) is
// handled entirely by [PowerSyncStorageImpl] via a conditional import — this file
// has no dart:io or kIsWeb references.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' as ps;

import '../database/powersync_schema.g.dart';
import '../database/powersync_storage.dart';

/// Process-wide [PowerSyncDatabase] handle.
///
/// Created once on first read and kept alive for the app's lifetime via
/// [ProviderRef.keepAlive]. Never re-opened, and never connected.
// Explicit variable type: this provider and [databaseProvider] reference each
// other from their initializers, and without the annotation the analyzer
// reports a top-level type-inference cycle.
final FutureProvider<ps.PowerSyncDatabase> powerSyncInstanceProvider =
    FutureProvider<ps.PowerSyncDatabase>((ref) async {
  ref.keepAlive();

  final db = await PowerSyncStorageImpl().openDatabase(powersyncSchema);

  ref.onDispose(db.close);

  return db;
});
