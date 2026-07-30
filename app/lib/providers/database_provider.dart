import 'package:drift/drift.dart';
import 'package:drift_sqlite_async/drift_sqlite_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../sync/domain_op_capture.dart';
import 'powersync_provider.dart';

/// The process-wide capture seam every DAO write path describes its effect
/// through.
///
/// One instance, constructed before sign-in and bound to nothing — which is the
/// state an un-enrolled device stays in for ever, authoring nothing. It is a
/// provider of its own rather than an inline argument to [databaseProvider]
/// because binding it is `sync_lifecycle_provider.dart`'s job and the two have to
/// reach the *same* object: a second instance would leave the store describing
/// its writes into a void while the lifecycle held a bound seam nobody wrote
/// through.
final Provider<WorkspaceRoutingOpCapture> domainOpCaptureProvider =
    Provider<WorkspaceRoutingOpCapture>((ref) => WorkspaceRoutingOpCapture());

/// Shared singleton [GtdDatabase] — kept alive for the app's lifetime.
///
/// The domain read model, and since #591 the store the op-log spine maintains:
/// DAO writes describe their effects through [domainOpCaptureProvider], and the
/// projector writes reduced state back into these tables.
///
/// Storage is still the same `SqliteConnection` that
/// [powerSyncInstanceProvider] owns, so Drift and the (disconnected) PowerSync
/// engine share a single on-disk SQLite file; #556 swaps that for a store of its
/// own. Because the PowerSync database opens asynchronously, the Drift executor is
/// wrapped in [DatabaseConnection.delayed]: any query issued before the underlying
/// future resolves is queued and flushed once it does. Tests construct
/// [GtdDatabase] directly with an in-memory executor.
// Explicit variable type: see the matching note on [powerSyncInstanceProvider].
final Provider<GtdDatabase> databaseProvider = Provider<GtdDatabase>((ref) {
  final connection = DatabaseConnection.delayed(Future(() async {
    final psDb = await ref.read(powerSyncInstanceProvider.future);
    return SqliteAsyncDriftConnection(psDb);
  }));
  final db = GtdDatabase(
    connection,
    opCapture: ref.read(domainOpCaptureProvider),
  );
  ref.onDispose(db.close);
  return db;
});
