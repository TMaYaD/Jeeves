/// An imported Nirvana export reaches every device (issue #610).
///
/// The import writes through the real DAOs on a real store, against real
/// Ed25519 and the real [SyncClient] — so what is asserted here is that a
/// *migration* converges, not that a reducer does. Pre-fix the import's `todos`,
/// `todo_tags` and `captures` writes were raw drift statements inside the
/// capturing scope: they committed rows and described nothing, so device B
/// received an import it could never see.
///
/// Four claims, in order of strength:
///
/// 1. An import on an enrolled device lands on the co-enrolled device as full
///    rows, and both agree on canonical reduced-state bytes.
/// 2. A device that enrols *afterwards*, with the passphrase alone, reaches the
///    same bytes from zero — the import is on the log, not merely in a peer's
///    store.
/// 3. Importing *before* enrolment still works: the initial-upload walk carries
///    the rows (#591). Neither ordering strands data any more.
/// 4. A second identical import authors no duplicate entities — ids are
///    deterministic, so a re-run converges rather than forking.
@TestOn('!browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/import/nirvana_local_import.dart';
import 'package:jeeves/sync/envelope.dart' show opClassContent;
import 'package:jeeves/sync/ids.dart' show jeevesWorkspaceNamespace;
import 'package:jeeves/sync/sync_lifecycle.dart' show SyncActivation;
import 'package:uuid/uuid.dart';

import '../test_helpers.dart';
import 'harness/fake_sync_server.dart';
import 'harness/reduced_state.dart';
import 'harness/sim_device.dart';
import 'harness/sim_workspace.dart';
import 'harness/stack_phone.dart';

const _userId = 'sim-user';

/// Every collection group the import touches, compared as **full rows**: no
/// column excluded, because every domain column is synced or derived at read
/// time.
const _importedTables = <String>[
  'todos',
  'tags',
  'todo_tags',
  'captures',
  'capture_tags',
];

/// A Nirvana JSON export exercising every entity kind the import writes: a
/// project (→ project Tag), a clarified child with a context tag, a `waitingfor`
/// child (→ person Tag + junction), and an Inbox row (state 0 → Capture with tag
/// hints).
const _exportJson = '['
    '{"cancelled":0,"deleted":0,"id":"proj-1","name":"Quarterly plan",'
    '"type":1,"state":11},'
    '{"cancelled":0,"deleted":0,"id":"task-next","name":"Draft the hiring line",'
    '"type":0,"state":1,"parentid":"proj-1","tags":",computer,","etime":30,'
    '"energy":2},'
    '{"cancelled":0,"deleted":0,"id":"task-waiting","name":"Sign-off from Alice",'
    '"type":0,"state":2,"parentid":"proj-1","waitingfor":"Alice"},'
    '{"cancelled":0,"deleted":0,"id":"task-inbox","name":"Random thought",'
    '"type":0,"state":0,"tags":",errand,"}'
    ']';

Future<ImportResult> _import(GtdDatabase domain) => importNirvanaLocally(
      bytes: Uint8List.fromList(utf8.encode(_exportJson)),
      filename: 'nirvana.json',
      format: 'json',
      userId: _userId,
      db: domain,
    );

int _contentOpCount(FakeSyncServer server) => server.storedOps
    .where((op) => op.header?.opClass == opClassContent)
    .length;

/// Every `table/id` the import produced, so "no duplicate entities" is a claim
/// about identity rather than about row counts alone.
Future<Set<String>> _entityKeys(GtdDatabase domain) async {
  final keys = <String>{};
  for (final table in _importedTables) {
    for (final row in await domainRows(domain, table)) {
      keys.add('$table/${row['id']}');
    }
  }
  return keys;
}

void main() {
  setUpAll(configureSqliteForTests);

  test('an import authors ops, so every device holds the imported data',
      () async {
    final workspace = await SimWorkspace.create(userId: _userId);
    addTearDown(workspace.close);
    final a = workspace.a;
    final b = workspace.b;

    final result = await _import(a.domain);
    expect(result.importedCount, 3);
    expect(result.projectTagsCreated, 1);

    await workspace.syncAll();

    // AC-1: B holds every imported entity, as full rows it never wrote itself.
    for (final table in _importedTables) {
      final rowsA = await domainRows(a.domain, table);
      expect(rowsA, isNotEmpty, reason: '$table is empty on the importer');
      expect(
        await domainRows(b.domain, table),
        rowsA,
        reason: '$table differs on B — the import authored no op for it',
      );
    }

    final bytesA = await canonicalReducedState(a.database);
    expect(await canonicalReducedState(b.database), bytesA,
        reason: 'A and B disagree on reduced state after an import');

    // Claim 2: a device enrolling afterwards, with the passphrase alone,
    // rebuilds the import from the log alone.
    final c = await SimDevice.create(
      label: 'C',
      userId: _userId,
      server: workspace.server,
      clock: workspace.clock,
      memberId:
          const Uuid().v5(jeevesWorkspaceNamespace, 'sim/device/import-c'),
      seed: Uint8List.fromList(List<int>.generate(32, (byte) => byte + 7)),
      passphrase: workspace.passphrase,
    );
    addTearDown(c.close);
    await c.sync();

    expect(await canonicalReducedState(c.database), bytesA,
        reason: 'a fresh device did not rebuild the import by replay');
    for (final table in _importedTables) {
      expect(
        await domainRows(c.domain, table),
        await domainRows(a.domain, table),
        reason: '$table differs on the replaying device',
      );
    }

    // The domain facts the import was supposed to produce, on every device.
    for (final device in [a, b, c]) {
      final store = device.domain;
      final projectTags = await store.tagDao.watchByType('project').first;
      expect(projectTags.map((t) => t.name), ['Quarterly plan'],
          reason: 'project tag missing on ${device.label}');
      final personTags = await store.tagDao.watchPersonTags().first;
      expect(personTags.map((t) => t.name), ['Alice'],
          reason: 'person tag missing on ${device.label}');
      final inbox = await store.captureDao.watchInbox().first;
      expect(inbox.map((c) => c.title), ['Random thought'],
          reason: 'the imported Capture is missing on ${device.label}');
    }
  });

  test('a second identical import authors no duplicate entities', () async {
    final workspace = await SimWorkspace.create(userId: _userId);
    addTearDown(workspace.close);
    final a = workspace.a;

    await _import(a.domain);
    await workspace.syncAll();
    final keysAfterFirst = await _entityKeys(a.domain);
    final bytesAfterFirst = await canonicalReducedState(a.database);

    await _import(a.domain);
    await workspace.syncAll();

    expect(await _entityKeys(a.domain), keysAfterFirst,
        reason: 're-importing forked an entity instead of landing on its id');
    expect(await canonicalReducedState(workspace.b.database),
        await canonicalReducedState(a.database),
        reason: 'A and B disagree after a re-import');
    // Re-import re-asserts the export-owned fields under a fresh clock, so the
    // bytes move; what must not move is the entity set above.
    expect(bytesAfterFirst, isNotEmpty);
  });

  test('an import before enrolment is carried by the initial-upload walk',
      () async {
    final server = FakeSyncServer();
    final clock = FakeClock(simulationStartWallMs);
    final phone = await StackPhone.create(
      label: 'A',
      userId: _userId,
      server: server,
      clock: clock,
    );
    addTearDown(phone.close);

    // The seam is bound to nothing on an un-enrolled device: the import
    // describes its effects into a void, by design.
    await _import(phone.domain);
    expect(phone.capture.isBound, isFalse);
    expect(await phone.syncStore.select(phone.syncStore.outbox).get(), isEmpty);

    final rowsBeforeEnrolment = <String, List<Map<String, Object?>>>{
      for (final table in _importedTables)
        table: await domainRows(phone.domain, table),
    };

    final passphrase = (await phone.enrolAsFirstDevice()).passphrase;
    expect(await phone.activate(), SyncActivation.active);
    expect(_contentOpCount(server), greaterThan(0));

    // The walk read the rows and the projector wrote them back: lossless.
    for (final table in _importedTables) {
      expect(await domainRows(phone.domain, table), rowsBeforeEnrolment[table],
          reason: '$table changed under the phone\'s own initial upload');
    }

    // A second phone, with the passphrase alone, receives the whole import.
    final second = await StackPhone.create(
      label: 'B',
      userId: _userId,
      server: server,
      clock: clock,
    );
    addTearDown(second.close);
    await second.enrolWithPassphrase(passphrase);
    expect(await second.activate(), SyncActivation.active);

    for (final table in _importedTables) {
      expect(await domainRows(second.domain, table), rowsBeforeEnrolment[table],
          reason: '$table did not reach the second phone');
    }
    expect(await canonicalReducedState(second.syncStore),
        await canonicalReducedState(phone.syncStore));
  });
}
