/// The gate that repairs a device already holding a hole (#605 §6).
///
/// A projection that raised left the ops durable, the cursor advanced and the
/// domain read model **permanently** short of every entity in that batch: the
/// next pull's `affected` set no longer names them, so it succeeds and the hole is
/// never filled. Dropping `UNIQUE (name, type)` stops new holes; it does not fill
/// the ones already on disk. The schema upgrade is what does, by forcing exactly
/// one full re-projection.
///
/// The trap this pins is that the naive gate is **inert, and silently so**:
/// `databaseProvider` wraps the executor in `DatabaseConnection.delayed`, so the
/// migration runs on the first *query*, not at construction. Anything read off the
/// database object straight after `ref.read(databaseProvider)` reports the
/// pre-migration state. So the provider forces the open with a throwaway `SELECT 1`
/// and then awaits `GtdDatabase.opened`, which a `beforeOpen` completes — not
/// `onUpgrade`, which never runs on a no-op launch and would leave the await
/// hanging for ever.
///
/// Asserted over a real on-disk store and a real device's op log, through the real
/// providers, because the delayed connection *is* the thing under test.
@TestOn('!browser')
library;

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift_sqlite_async/drift_sqlite_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/domain_store.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/sync_stack_provider.dart';

import '../sync/harness/fake_sync_server.dart';
import '../sync/harness/sim_device.dart';
import '../sync/harness/sim_workspace.dart' show simulationStartWallMs;
import '../test_helpers.dart';

const String _userId = 'gate-user';
const String _outcomeId = '3f2d1c4e-5a6b-4c8d-9e0f-1a2b3c4d5e6f';

void main() {
  setUpAll(configureSqliteForTests);

  late Directory directory;
  late SimDevice device;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    directory = Directory.systemTemp.createTempSync('jeeves_rebuild_gate_');
    device = await SimDevice.create(
      label: 'A',
      userId: _userId,
      server: FakeSyncServer(),
      clock: FakeClock(simulationStartWallMs),
    );
    // Real reduced state, produced by a real DAO write through the real reduce
    // path — the thing a re-projection has to be able to recover from.
    await device.domain.todoDao.insertOutcome(
      id: _outcomeId,
      title: 'Ring Alice back',
      userId: _userId,
      now: device.clock.asDateTime,
    );
  });

  tearDown(() async {
    await device.close();
    try {
      directory.deleteSync(recursive: true);
    } on FileSystemException {
      // best-effort
    }
  });

  /// Bring the on-disk store to a *completed-replay* state at [schemaVersion],
  /// with the domain row deliberately missing — the hole an aborted projection
  /// left behind.
  Future<void> seedStoreAt(int schemaVersion) async {
    final opening = await openDomainStoreIn(directory.path);
    final db = GtdDatabase(SqliteAsyncDriftConnection(opening.database));
    // The first query is what runs onCreate, which builds the current schema.
    await db.customSelect('SELECT 1').getSingle();
    expect(await db.select(db.todos).get(), isEmpty,
        reason: 'the hole: reduced state has the Outcome, the read model does not');
    await db.customStatement('PRAGMA user_version = $schemaVersion');
    // The marker a *finished* replay writes. With it present the ordinary
    // `needsRebuild` gate is closed, so anything that re-projects from here does
    // so because of the upgrade and for no other reason.
    opening.markRebuilt();
    await db.close();
    await opening.database.close();
  }

  ProviderContainer containerOverDirectory() {
    final container = ProviderContainer(overrides: [
      domainStoreProvider.overrideWith((ref) async {
        final opening = await openDomainStoreIn(directory.path);
        ref.onDispose(opening.database.close);
        return opening;
      }),
      syncDatabaseProvider.overrideWith((ref) async => device.database),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  test('a v2 store re-projects once on the upgrade to v3', () async {
    await seedStoreAt(2);
    final container = containerOverDirectory();

    final projected = await container.read(domainStoreRebuildProvider.future);

    expect(projected, greaterThan(0),
        reason: 'the upgrade forces the one re-projection that fills the hole');
    final db = container.read(databaseProvider);
    final rows = await db.select(db.todos).get();
    expect(rows.map((row) => row.id), [_outcomeId],
        reason: 'the permanent hole is filled');
    final details = await db.opened;
    expect(details.hadUpgrade, isTrue);
    expect(details.versionBefore, 2);
    expect(details.versionNow, 3);
  });

  test('`opened` completes on a launch that migrates nothing', () async {
    // The reason the completer is fed from `beforeOpen` rather than `onUpgrade`:
    // drift runs `beforeOpen` on *every* open, so the future always resolves. A
    // completer fed only by `onUpgrade` would hang here for ever, and the app
    // would never get past the gate.
    await seedStoreAt(3);
    final container = containerOverDirectory();

    final projected = await container.read(domainStoreRebuildProvider.future);

    expect(projected, 0, reason: 'nothing to upgrade, nothing to re-project');
    final details = await container.read(databaseProvider).opened;
    expect(details.hadUpgrade, isFalse);
    expect(details.wasCreated, isFalse);
  });

  test('the migration has not run when the provider hands back the database',
      () async {
    // The trap, pinned as behaviour so the inert gate cannot come back: the
    // executor is `DatabaseConnection.delayed`, so at the moment
    // `ref.read(databaseProvider)` returns, no migration has run — on a store that
    // is about to be upgraded. Any synchronous "did we upgrade?" read there is
    // false, and the forced re-projection would never happen.
    await seedStoreAt(2);
    final container = containerOverDirectory();
    // Resolve the store, but do NOT issue a query against it.
    await container.read(domainStoreProvider.future);
    final db = container.read(databaseProvider);

    var openedAlready = false;
    unawaited(db.opened.then((_) => openedAlready = true));
    await Future<void>.delayed(Duration.zero);
    expect(openedAlready, isFalse,
        reason: 'the migration runs on the first query, not at construction — '
            'which is why the gate forces one before awaiting `opened`');

    // Force the open the way the provider does, and the truth appears.
    await db.customSelect('SELECT 1').getSingle();
    expect((await db.opened).hadUpgrade, isTrue);
  });
}
