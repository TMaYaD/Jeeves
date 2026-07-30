// One-shot post-sync fixups that have to wait until the first sync has brought
// other devices' rows in.
//
// **Repointed at the spine (#591).** It used to wait on PowerSync's
// `hasSynced`, which never flips now that the engine does not connect: the hook
// would never fire and the provider would hold a dangling status-stream listener
// for the process's lifetime. The equivalent signal is
// `SyncLifecycle.firstSyncSettled`, which completes once both Workspace clients
// have pulled.
//
// Kept rather than pruned with the #556 inventory because the job survives the
// flip. `dedupeTags` merges Tags two devices minted independently, and Tag ids
// are random UUIDv4s by rule (`sync/ids.dart` — only junctions and preferences
// derive theirs), so two devices creating "Home" offline still converge on two
// entities. Nothing about the op log makes that impossible; the projector
// realigns derived ids, not names.
//
// Reads [databaseProvider] so the hook drives its DAO directly: a single source
// of truth, exercised by the same tests prod runs through.
//
// Eager materialisation: this provider must be `ref.watch`-ed once from the
// widget tree (see main.dart) so its build runs at startup and the hook actually
// wires up. Otherwise it stays lazy and dedupe never fires.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database_provider.dart';
import 'sync_lifecycle_provider.dart';

final postSyncHooksProvider = Provider<void>((ref) {
  ref.keepAlive();

  final db = ref.read(databaseProvider);
  var disposed = false;
  var ran = false;

  Future<void> runOnce() async {
    if (ran || disposed) return;
    // `ran` latches before the awaited work — a failed dedupe will not
    // retry until cold start.  Acceptable trade-off: dedupe is idempotent
    // best-effort cleanup, and a persistent failure surfaces more usefully
    // as one stack trace than as a retry storm.
    ran = true;
    try {
      await db.tagDao.dedupeTags();
    } catch (_) {
      // Best-effort cleanup; never crash the app over dedup failure.
    }
  }

  // `Provider`'s builder cannot be async, so kick off the waiting in the
  // background. A device with nobody signed in has no lifecycle and never
  // arms — the same non-effect an unconnected engine's `hasSynced` had, and the
  // right one: a device that has never synced has no foreign duplicates to
  // merge.
  Future<void> setup() async {
    final lifecycle = await ref.read(syncLifecycleProvider.future);
    if (disposed || lifecycle == null) return;
    await lifecycle.firstSyncSettled;
    if (disposed) return;
    await runOnce();
  }

  unawaited(setup());

  ref.onDispose(() => disposed = true);
});
