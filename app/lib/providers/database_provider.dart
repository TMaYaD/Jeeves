import 'package:drift/drift.dart';
import 'package:drift_sqlite_async/drift_sqlite_async.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqlite_async/sqlite_async.dart' show SqliteDatabase;

import '../database/domain_store.dart';
import '../database/gtd_database.dart';
import '../sync/domain_op_capture.dart';
import '../sync/domain_rebuild.dart';
import '../sync/hlc.dart';
import '../sync/host/hosted_capture.dart';
import 'sync_stack_provider.dart';

/// The device's one HLC state, shared by the domain store's capture binding, the
/// sync host and the op-log stack. Every stamp names its own node id, so the
/// default member id here is never used.
final Provider<HlcClock> deviceClockProvider = Provider<HlcClock>(
  (ref) => HlcClock(
    memberIdHex: '0' * 32,
    nowMs: () => DateTime.now().millisecondsSinceEpoch,
  ),
);

/// The binding every DAO write path describes its effect through: it stages each
/// coalesced change into `pending_changes`, in the write's own transaction, and
/// asks the sync host to drain it after the commit. One instance, so the store and
/// the host reach the same object.
final Provider<HostedDomainOpCapture> hostedDomainOpCaptureProvider =
    Provider<HostedDomainOpCapture>(
  (ref) => HostedDomainOpCapture(clock: ref.read(deviceClockProvider)),
);

/// The interim op-log bridge: the sync host hands it each merged local change and
/// it routes the change to the Workspace client that authors it.
///
/// One instance, constructed before sign-in and bound to nothing — which is the
/// state an un-enrolled device stays in for ever, authoring no ops. It is a
/// provider of its own because binding it is `sync_lifecycle_provider.dart`'s job
/// and the lifecycle and the host have to reach the *same* object.
final Provider<WorkspaceRoutingOpCapture> domainOpCaptureProvider =
    Provider<WorkspaceRoutingOpCapture>((ref) => WorkspaceRoutingOpCapture());

/// The domain store's own SQLite file, opened once.
///
/// Two stores per device by design (see `sync/domain_projector.dart`): this one is
/// the domain read model, `syncDatabaseProvider`'s is the convergence substrate.
/// It reports whether the op log still owes it a replay — which is what
/// [domainStoreRebuildProvider] keys on. The open creates its own file and
/// deletes nothing (issue #673).
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
    opCapture: ref.read(hostedDomainOpCaptureProvider),
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
/// It also resolves to 0 on a launch that neither owes a replay nor upgraded the
/// schema.
///
/// **Ordering.** It runs as early as the app can run anything, but it does not
/// hold the first frame: the projector fires the view notifies for every
/// collection it touched, so a watcher that attached before the replay finished
/// still refreshes when it does. Blocking startup on a walk of the whole store to
/// gain a guarantee the notifies already provide would be the worse trade.
///
/// **Two gates, either of which opens the walk.**
///
/// The first is the marker a *finished* replay writes, not the store's existence,
/// so a replay that threw is retried on the next launch rather than skipped for
/// ever with the log's reduced state stranded (`database/domain_store_io.dart`).
///
/// The second is **a schema upgrade**, and it is a repair (#605). Before `tags`
/// lost its `UNIQUE (name, type)`, a peer's duplicate Tag made the projector raise
/// *after* every op in the batch was durable and the cursor had advanced — so the
/// ops sit in the log for ever, the server never re-serves those seqs, and the read
/// model keeps a **permanent hole** covering every Outcome, Action, Capture and
/// TimeLog that shared the batch. Nothing routine fills it: the next pull's
/// `affected` set no longer names those entities. The v2→v3 upgrade therefore
/// triggers exactly one full re-projection, which is idempotent on reduced state,
/// and existing users' holes close with it.
///
/// **Forcing the open is load-bearing.** [databaseProvider] wraps the executor in
/// `DatabaseConnection.delayed`, so the migration runs on the first *query*, not at
/// construction: any "did we upgrade?" read taken straight after
/// `ref.read(databaseProvider)` reports the pre-migration state and the gate would
/// be silently inert. Hence the throwaway `SELECT 1` before awaiting
/// [GtdDatabase.opened] — a future fed by `beforeOpen`, which drift runs on every
/// open, so a launch that migrates nothing resolves it rather than hanging here.
///
/// **The walk does not hold the store.** The projector takes the writer in
/// small chunks (`sync/domain_projector.dart`), so an edit made while a
/// re-projection of the whole store is under way waits for one chunk, not for
/// the walk.
///
/// **A failure is logged, not swallowed.** It propagates into this provider's
/// error state as well, but nothing reads that state — the console line is what a
/// missing-data report is diagnosed from, the same convention
/// `sync_lifecycle_provider.dart` follows for a failed activation.
final FutureProvider<int> domainStoreRebuildProvider =
    FutureProvider<int>((ref) async {
  ref.keepAlive();
  final opening = await ref.read(domainStoreProvider.future);
  final domain = ref.read(databaseProvider);
  // Resolve the delayed connection and run the migration, then read its verdict.
  await domain.customSelect('SELECT 1').getSingle();
  final details = await domain.opened;
  if (!opening.needsRebuild && !details.hadUpgrade) return 0;
  final walk = Stopwatch()..start();
  try {
    final projected = await rebuildDomainFromOpLog(
      sync: await ref.read(syncDatabaseProvider.future),
      domain: domain,
    );
    opening.markRebuilt();
    // One line per walk that did anything: how much it covered and how long it
    // took is the first thing a "the app was slow after the update" report
    // needs, and nothing else records it.
    if (projected > 0) {
      debugPrint(
        'domain store rebuild: projected $projected entities in '
        '${walk.elapsedMilliseconds} ms '
        '(${details.hadUpgrade ? 'schema upgrade '
            '${details.versionBefore} -> ${details.versionNow}' : 'first replay'})',
      );
    }
    return projected;
  } on Object catch (error) {
    debugPrint('domain store rebuild: failed, will retry next launch — $error');
    rethrow;
  }
});
