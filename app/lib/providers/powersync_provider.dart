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
    await pending;
    await db.close();
  });

  return db;
});
