/// The first open of a fresh domain store rebuilds it from the local op log
/// (issue #595).
///
/// The store swap deletes the PowerSync-era file rather than converting it, so
/// for an enrolled device the op log is the only thing standing between "new
/// store" and "no data". This asserts the replay over a *real* device: a
/// `SimDevice` writes through its DAOs, its writes are reduced by the production
/// reduce path, and then a brand-new `GtdDatabase` — the fresh file's stand-in —
/// is rebuilt from that device's `SyncDatabase`.
///
/// Nothing is stubbed on the way in. If the reduce path did not carry a field,
/// the rebuild cannot invent it, which is exactly the property that makes this a
/// statement about the cutover rather than about the test.
@TestOn('!browser')
library;

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/sync/domain_rebuild.dart';
import 'package:jeeves/sync/sync_database.dart';

import 'harness/fake_sync_server.dart';
import 'harness/sim_device.dart';
import 'harness/sim_workspace.dart' show simulationStartWallMs;

const String _userId = 'rebuild-user';

void main() {
  late FakeSyncServer server;
  late FakeClock clock;

  setUp(() {
    // Every store here is its own in-memory database, so there is nothing to
    // race — Drift's warning is about several databases over one executor.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    server = FakeSyncServer();
    clock = FakeClock(simulationStartWallMs);
  });

  /// The fresh file's stand-in: a store Drift has just created and nothing has
  /// written.
  GtdDatabase freshDomainStore() {
    final db = GtdDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    return db;
  }

  test('an empty log leaves the store empty rather than failing', () async {
    // The user's own phone on cutover day: never enrolled, nothing reduced. The
    // sanctioned path from here is sign-up → enrolment → re-import, and this is
    // the state that path starts from.
    final sync = SyncDatabase(NativeDatabase.memory());
    addTearDown(sync.close);
    final domain = freshDomainStore();

    expect(await rebuildDomainFromOpLog(sync: sync, domain: domain), 0);
    expect(await domain.select(domain.todos).get(), isEmpty);
  });

  test('reduced state lands in the fresh store', () async {
    final device = await SimDevice.create(
      label: 'A',
      userId: _userId,
      server: server,
      clock: clock,
    );
    addTearDown(device.close);

    await device.domain.todoDao.insertOutcome(
      id: '3f2d1c4e-5a6b-4c8d-9e0f-1a2b3c4d5e6f',
      title: 'Ship the greenfield cut',
      userId: _userId,
      now: device.clock.asDateTime,
    );
    await device.domain.todoDao.insertOutcome(
      id: '4a3e2d5f-6b7c-4d9e-8f01-2b3c4d5e6f70',
      title: 'Re-import from Nirvana',
      userId: _userId,
      now: device.clock.asDateTime,
    );
    // Reduced locally at authoring time: the capture seam signs, appends and
    // applies in one scope, so the log is the record without a server round trip.

    final rebuilt = freshDomainStore();
    final projected =
        await rebuildDomainFromOpLog(sync: device.database, domain: rebuilt);

    expect(projected, greaterThan(0));
    final titles = (await rebuilt.select(rebuilt.todos).get())
        .map((row) => row.title)
        .toSet();
    expect(titles, {'Ship the greenfield cut', 'Re-import from Nirvana'});
  });

  test('a tombstoned entity does not come back', () async {
    final device = await SimDevice.create(
      label: 'A',
      userId: _userId,
      server: server,
      clock: clock,
    );
    addTearDown(device.close);

    await device.domain.todoDao.insertOutcome(
      id: '5b4f3e60-7c8d-4e01-9f12-3c4d5e6f7081',
      title: 'Deleted before the swap',
      userId: _userId,
      now: device.clock.asDateTime,
    );
    await device.domain.todoDao.deleteOutcome('5b4f3e60-7c8d-4e01-9f12-3c4d5e6f7081');

    final rebuilt = freshDomainStore();
    await rebuildDomainFromOpLog(sync: device.database, domain: rebuilt);

    // The reduced substrate never forgets an entity — it tombstones it — so a
    // rebuild that only replayed live fields would resurrect this row.
    expect(await rebuilt.select(rebuilt.todos).get(), isEmpty);
  });

  test('running the rebuild twice produces the same store', () async {
    final device = await SimDevice.create(
      label: 'A',
      userId: _userId,
      server: server,
      clock: clock,
    );
    addTearDown(device.close);

    await device.domain.todoDao.insertOutcome(
      id: '6c5041e7-8d9e-4f12-a023-4d5e6f708192',
      title: 'Idempotent',
      userId: _userId,
      now: device.clock.asDateTime,
    );

    final rebuilt = freshDomainStore();
    await rebuildDomainFromOpLog(sync: device.database, domain: rebuilt);
    final afterOnce = await rebuilt.select(rebuilt.todos).get();
    await rebuildDomainFromOpLog(sync: device.database, domain: rebuilt);
    final afterTwice = await rebuilt.select(rebuilt.todos).get();

    // Idempotence is what makes it safe to run on every fresh open without a
    // "have I done this" flag, and what makes a crash mid-rebuild recoverable.
    expect(afterTwice, afterOnce);
  });

  test('a duplicate (name, type) pair in reduced state rebuilds and folds',
      () async {
    // The replay tail is the second of the two routes a peer's Tag reaches the
    // domain store by, and the one that repairs a device rebuilt from its own log.
    // The rebuild must both *represent* the duplicate — the projection of reduced
    // state cannot refuse what reduced state holds — and then fold it, so the
    // device does not come out of the rebuild showing two "Alice" rows.
    final device = await SimDevice.create(
      label: 'A',
      userId: _userId,
      server: server,
      clock: clock,
    );
    addTearDown(device.close);

    // Two Tag entities for one pair, exactly as two devices produce them: random
    // ids by protocol policy, so `findOrCreateTag` on each device forks.
    const small = 'aaaaaaaa-0000-4000-8000-000000000001';
    const large = 'bbbbbbbb-0000-4000-8000-000000000002';
    const outcomeId = '7d61520f-9eaf-4023-b134-5e6f70819203';
    await device.domain.todoDao.insertOutcome(
      id: outcomeId,
      title: 'Ring Alice back',
      userId: _userId,
      now: device.clock.asDateTime,
    );
    for (final id in [large, small]) {
      await device.domain.tagDao.upsertTag(TagsCompanion(
        id: Value(id),
        name: const Value('Alice'),
        type: const Value('person'),
        userId: const Value(_userId),
      ));
    }
    await device.domain.tagDao.assignTag(outcomeId, large, _userId);

    final rebuilt = freshDomainStore();
    await rebuildDomainFromOpLog(sync: device.database, domain: rebuilt);

    final tags = await rebuilt.select(rebuilt.tags).get();
    expect(tags.map((row) => row.id), [small],
        reason: 'the replay tail reconciles, folding onto MIN(id)');
    final junctions = await rebuilt.select(rebuilt.todoTags).get();
    expect(junctions.map((row) => row.tagId), [small],
        reason: 'the assignment followed the fold');

    // Still idempotent with the reconciler in the loop: the second rebuild finds
    // no duplicate group and no dangling junction, so it changes nothing.
    await rebuildDomainFromOpLog(sync: device.database, domain: rebuilt);
    expect(await rebuilt.select(rebuilt.tags).get(), tags);
    expect(await rebuilt.select(rebuilt.todoTags).get(), junctions);
  });
}
