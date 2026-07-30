// The on-device SQLite store the domain read model lives in.
//
// **PowerSync is the storage engine here and nothing else. It does not
// connect.** #591 flipped the op-log spine on as the production sync path, so
// this provider opens the database, runs the two startup fixups that have to
// happen before anything reads it, and stops. There is no `connect()`, no
// connector, and no `currentUserIdProvider` listener — a signed-in device does
// not replicate to the legacy mirrored Postgres tables.
//
// That disconnection is required rather than tidy. The user's own cutover is
// sign-out → sign-up as a *new* account, so on the first launch afterwards the
// session token is the new account's and `_handleMigration` has reassigned every
// local row — which enqueues all of them in `ps_crud`. A connector would upload
// the entire migrated store into the new account's legacy tables: a second, live
// sync path beside the op log, into tables #556 deletes. Teeing writes into both
// is exactly the dual-write branching the Implementation stance forbids.
//
// `ps_crud` therefore grows with nothing draining it, bounded by one user's
// writes over the confidence window. Local writes enqueue because the tables are
// PowerSync-managed, which cannot be turned off without the fresh-store swap
// that #556 owns; the queue costs disk and nothing else, and the file goes with
// the engine. `services/backend_connector.dart` survives until #556 removes it
// there, with the rest of the engine.
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
import '../services/migration_service.dart'
    show migrateLocalInboxToCaptures, reconcileActionsAtStartup;

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

  // Carve a local-only user's Inbox out of `todos` into `captures` before
  // anything reads it (issue #184 Phase 2). A signed-in user got the equivalent
  // move server-side from Alembic 0026 while the legacy path was live; a user who
  // has never signed in has no server to do it, so without this their Inbox would
  // vanish the moment the UI started reading `captures`. Idempotent and
  // insert-before-delete, so it is safe on every launch.
  await migrateLocalInboxToCaptures(db);

  // Repair the Action grain before anything reads it (ADR-0001 story 9, issue
  // #479; ADR-0022). One pass: converge an accidental multi-`current` set onto
  // the writers' deterministic winner, retiring the losers. It reads `actions`
  // and nothing else — the legacy `todos.next_action_text` cursor has no readers
  // left, and no longer exists to acquire one (ADR-0024). It never overwrites an
  // Action's text and never stamps `last_clarified_at` (ADR-0012). Like the
  // migration above it runs before any watcher exists, so no view-notify.
  //
  // It writes raw SQL and therefore authors **no op** — see its own docstring for
  // why that is the right trade rather than an oversight.
  await reconcileActionsAtStartup(db);

  ref.onDispose(db.close);

  return db;
});
