// One-shot post-sync fixups that have to wait until PowerSync's initial
// replication has finished.  Kept out of [powerSyncInstanceProvider] so
// that provider stays a thin owner of the PowerSync connection — it does
// not need to know which tables require domain-level fixup.  Adding a new
// hook (different table, different rule) means extending the listener
// here, not bloating the sync provider with raw-SQL clones of DAO logic.
//
// Reads [databaseProvider] so each hook drives its DAO directly: a single
// source of truth, exercised by the same tests prod runs through.  No
// import cycle — the dependency chain is one-way:
//   postSyncHooksProvider → databaseProvider → powerSyncInstanceProvider
//
// Eager materialisation: this provider must be `ref.watch`-ed once from
// the widget tree (see main.dart) so its build runs at startup and the
// hook actually wires up.  Otherwise it stays lazy and dedupe never
// fires.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' as ps;

import 'database_provider.dart';
import 'powersync_provider.dart';

final postSyncHooksProvider = Provider<void>((ref) {
  ref.keepAlive();

  final db = ref.read(databaseProvider);
  StreamSubscription<ps.SyncStatus>? sub;
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

  // `Provider`'s builder cannot be async, so kick off the wiring in the
  // background.  PowerSync's `connect()` resolves once the websocket is
  // established, not once the initial download finishes — rows keep
  // streaming in afterwards — so we wait for `hasSynced == true`, which
  // PowerSync flips after the first replication cycle completes.
  Future<void> setup() async {
    final psDb = await ref.read(powerSyncInstanceProvider.future);
    if (disposed) return;
    if (psDb.currentStatus.hasSynced == true) {
      await runOnce();
      return;
    }
    sub = psDb.statusStream.listen((status) {
      if (status.hasSynced != true) return;
      sub?.cancel();
      sub = null;
      unawaited(runOnce());
    });
  }

  unawaited(setup());

  ref.onDispose(() async {
    disposed = true;
    await sub?.cancel();
    sub = null;
  });
});
