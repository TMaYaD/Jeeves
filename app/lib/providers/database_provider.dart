import 'package:drift/drift.dart';
import 'package:drift_sqlite_async/drift_sqlite_async.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqlite_async/sqlite_async.dart' show SqliteDatabase;

import '../database/domain_store.dart';
import '../database/gtd_database.dart';
import '../sync/domain_op_capture.dart';
import '../sync/domain_rebuild.dart';
import 'sync_stack_provider.dart';

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

/// The domain store's own SQLite file, opened once.
///
/// Two stores per device by design (see `sync/domain_projector.dart`): this one is
/// the domain read model, `syncDatabaseProvider`'s is the convergence substrate.
/// Opening this one also disposes of the PowerSync-era `jeeves.sqlite`
/// (ADR-0035), and reports whether the op log still owes it a replay — which is
/// what [domainStoreRebuildProvider] keys on.
final FutureProvider<DomainStoreOpening> domainStoreProvider =
    FutureProvider<DomainStoreOpening>((ref) async {
  ref.keepAlive();
  final opening = await DomainStoreImpl().openDatabase();
  ref.onDispose(opening.database.close);
  return opening;
});

/// Shared singleton [GtdDatabase] — kept alive for the app's lifetime.
///
/// The domain read model, and since #591 the store the op-log spine maintains:
/// DAO writes describe their effects through [domainOpCaptureProvider], and the
/// projector writes reduced state back into these tables.
///
/// Because the store opens asynchronously, the Drift executor is wrapped in
/// [DatabaseConnection.delayed]: any query issued before the underlying future
/// resolves is queued and flushed once it does. Tests construct [GtdDatabase]
/// directly with an in-memory executor.
// Explicit variable type: the analyzer reports a top-level type-inference cycle
// without it, because this provider and its dependencies reference each other
// from their initializers.
final Provider<GtdDatabase> databaseProvider = Provider<GtdDatabase>((ref) {
  final connection = DatabaseConnection.delayed(Future(() async {
    final SqliteDatabase store = (await ref.read(domainStoreProvider.future)).database;
    return SqliteAsyncDriftConnection(store);
  }));
  final db = GtdDatabase(
    connection,
    opCapture: ref.read(domainOpCaptureProvider),
  );
  ref.onDispose(db.close);
  return db;
});

/// Replays the local op log into a freshly created domain store, once.
///
/// Eagerly watched from `main.dart`, because a lazy provider is a rebuild that
/// never runs. It resolves to the number of entities projected: 0 on every launch
/// after the first, and on a device that has never synced.
///
/// **Ordering.** It runs as early as the app can run anything, but it does not
/// hold the first frame: the projector fires the ADR-0010 view notifies for every
/// collection it touched, so a watcher that attached before the replay finished
/// still refreshes when it does. Blocking startup on a walk of the whole store to
/// gain a guarantee the notifies already provide would be the worse trade.
///
/// **Only until it has completed once.** A store that already holds the
/// projection does not want the walk again — but the gate is the marker a
/// *finished* replay writes, not the store's existence, so a replay that threw is
/// retried on the next launch rather than skipped for ever with the log's reduced
/// state stranded (`database/domain_store_io.dart`).
///
/// **A failure is logged, not swallowed.** It propagates into this provider's
/// error state as well, but nothing reads that state — the console line is what a
/// missing-data report is diagnosed from, the same convention
/// `sync_lifecycle_provider.dart` follows for a failed activation.
final FutureProvider<int> domainStoreRebuildProvider =
    FutureProvider<int>((ref) async {
  ref.keepAlive();
  final opening = await ref.read(domainStoreProvider.future);
  if (!opening.needsRebuild) return 0;
  try {
    final projected = await rebuildDomainFromOpLog(
      sync: await ref.read(syncDatabaseProvider.future),
      domain: ref.read(databaseProvider),
    );
    opening.markRebuilt();
    return projected;
  } on Object catch (error) {
    debugPrint('domain store rebuild: failed, will retry next launch — $error');
    rethrow;
  }
});
