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
//
// Platform-specific storage (file path on native, OPFS on web) is
// handled entirely by [PowerSyncStorageImpl] via a conditional import —
// this file has no dart:io or kIsWeb references.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' as ps;

import '../database/daos/tag_dao.dart' show todoTagIdFor;
import '../database/powersync_schema.g.dart';
import '../database/powersync_storage.dart';
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

  final db = await PowerSyncStorageImpl().openDatabase(powersyncSchema);

  // Bridge the current auth state to PowerSync's connection lifecycle.
  // [currentUserIdProvider] holds `'local'` when no-one is logged in and
  // the real user id otherwise.  Transitions drive connect/disconnect.
  //
  // All transitions are serialized through [pending] so a rapid
  // login → logout (or vice-versa) can never interleave connect() and
  // disconnect() calls on the same PowerSync DB.
  Future<void> pending = Future.value();
  var disposed = false;
  var dedupeRan = false;
  StreamSubscription<ps.SyncStatus>? syncStatusSub;

  void runDedupe() {
    if (dedupeRan) return;
    dedupeRan = true;
    // Chain onto [pending] so disposal awaits dedupe before closing the db
    // — a bare Future<void>(...) here could race db.close().  Extending
    // [pending] also defers execution past the current applyUser
    // continuation, so anything observing this provider's future has
    // resolved before queries fire.
    //
    // Runs against the PowerSync SqliteConnection directly rather than via
    // [databaseProvider] — importing that provider here would form a
    // top-level cycle (databaseProvider already reads
    // [powerSyncInstanceProvider]). Writes still flow through PowerSync's
    // INSTEAD OF triggers and reach the upload queue.
    //
    // Runs once per provider lifetime (cold start to dispose) and is
    // idempotent — a no-op when there are no `(name, type)` duplicates.
    pending = pending.then((_) async {
      if (disposed) return;
      try {
        await _dedupeTags(db);
      } catch (_) {
        // Best-effort cleanup; never crash the app over dedup failure.
      }
    });
  }

  void scheduleDedupe() {
    if (dedupeRan || syncStatusSub != null) return;
    // PowerSync's `connect()` resolves once the websocket is established, not
    // once the initial download finishes — rows keep streaming in afterwards.
    // Running dedupe immediately would be a no-op on a fresh device (no
    // duplicates have arrived yet) and the `dedupeRan` flag would then block
    // every future attempt. Wait for `hasSynced == true`, which PowerSync
    // flips after the first replication cycle completes.
    if (db.currentStatus.hasSynced == true) {
      runDedupe();
      return;
    }
    syncStatusSub = db.statusStream.listen((status) {
      if (status.hasSynced != true) return;
      syncStatusSub?.cancel();
      syncStatusSub = null;
      runDedupe();
    });
  }

  Future<void> applyUser(String userId) {
    final next = pending.then((_) async {
      // Skip if disposal began while this transition was queued, so we
      // never call connect()/disconnect() on a closing database.
      if (disposed) return;
      if (userId == 'local') {
        await db.disconnect();
      } else {
        final connector = JevesBackendConnector(ref.read(apiServiceProvider));
        await db.connect(connector: connector);
        // Arm a one-shot dedupe pass for when PowerSync reports its first
        // completed replication cycle (`hasSynced`). Deletes flow through
        // PowerSync's INSTEAD OF triggers and reach the backend, so cloud
        // duplicates do not resync on next startup.
        scheduleDedupe();
      }
    }).catchError((Object e, StackTrace st) {
      // Swallow so one failed transition doesn't poison the chain — errors
      // are observable via PowerSync's status stream.
    });
    pending = next;
    return next;
  }

  // Subscribe BEFORE the initial apply.  On cold start, auth restoration
  // runs concurrently with this provider's build() and can flip
  // [currentUserIdProvider] from `'local'` to the real user id during the
  // `await` below.  If we subscribed after that await, such transitions
  // would land in the gap — [ref.listen] does not fire for existing
  // state — and PowerSync would stay disconnected until the next manual
  // login/logout.  The [pending] chain serialises the initial apply with
  // any listener-triggered apply, so the correct end state is reached
  // regardless of ordering.
  final sub = ref.listen<String>(
    currentUserIdProvider,
    (previous, next) {
      if (previous == next) return;
      if (disposed) return;
      // Enqueue the transition; the serial chain above ensures it runs
      // strictly after any in-flight connect/disconnect completes.
      unawaited(applyUser(next));
    },
  );
  await applyUser(ref.read(currentUserIdProvider));

  // Single async disposal: mark disposed, cancel the listener, drain any
  // in-flight transition, then close the DB.  Registering close() hooks
  // separately could otherwise race with a queued applyUser() that's
  // about to touch a closing database.
  ref.onDispose(() async {
    disposed = true;
    sub.close();
    await syncStatusSub?.cancel();
    syncStatusSub = null;
    await pending;
    await db.close();
  });

  return db;
});

/// Collapses duplicate `(name, type)` tag rows into a single canonical row.
///
/// Operates on the `tags` view directly via raw SQL so PowerSync's
/// `INSTEAD OF` triggers fire and the deletes/updates flow into the upload
/// queue — without this, deletes against the local `ps_data__tags` table
/// would never reach the backend, leaving cloud duplicates that resync on
/// next startup.
///
/// Canonicalisation rule for each `(name, type)` group with > 1 row: the row
/// with the most `todo_tags` references wins, with `MIN(id)` as the
/// deterministic tiebreaker. Junction rows on losing tag ids are repointed to
/// the canonical id; the deterministic junction id derived via
/// [todoTagIdFor] makes any collision on `(todo_id, canonical_tag_id)`
/// collapse under `INSERT OR REPLACE` on the backing table's id PK.
///
/// Mirrors `TagDao.dedupeTags` but stays free of the Drift dependency so the
/// PowerSync provider doesn't have to import [databaseProvider] (which would
/// create a top-level cycle).
Future<void> _dedupeTags(ps.PowerSyncDatabase db) async {
  await db.writeTransaction((tx) async {
    final groupRows = await tx.getAll(
      'SELECT name, type FROM tags GROUP BY name, type HAVING COUNT(*) > 1',
    );
    if (groupRows.isEmpty) return;

    for (final group in groupRows) {
      final name = group['name'] as String;
      final type = group['type'] as String;

      final candidates = await tx.getAll(
        'SELECT t.id AS id, '
        '(SELECT COUNT(*) FROM todo_tags WHERE tag_id = t.id) AS ref_count '
        'FROM tags t WHERE t.name = ? AND t.type = ? '
        'ORDER BY ref_count DESC, t.id ASC',
        [name, type],
      );
      if (candidates.length < 2) continue;

      final keepId = candidates.first['id'] as String;
      final dupIds = [
        for (final row in candidates.skip(1)) row['id'] as String,
      ];

      for (final dupId in dupIds) {
        final junctionRows = await tx.getAll(
          'SELECT id, todo_id, user_id FROM todo_tags WHERE tag_id = ?',
          [dupId],
        );
        for (final row in junctionRows) {
          final oldJunctionId = row['id'] as String;
          final todoId = row['todo_id'] as String;
          final userId = row['user_id'] as String;
          final newJunctionId = todoTagIdFor(todoId, keepId);
          await tx.execute(
            'INSERT OR REPLACE INTO todo_tags (id, todo_id, tag_id, user_id) '
            'VALUES (?, ?, ?, ?)',
            [newJunctionId, todoId, keepId, userId],
          );
          if (oldJunctionId != newJunctionId) {
            await tx.execute(
              'DELETE FROM todo_tags WHERE id = ?',
              [oldJunctionId],
            );
          }
        }
        await tx.execute('DELETE FROM tags WHERE id = ?', [dupId]);
      }
    }
  });
}
