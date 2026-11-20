/// Failures partway through a drain or a remote batch must not lose what
/// already merged, and an older sync store must upgrade without losing merge
/// state.
@TestOn('!browser')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/collection_codecs.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/host/change.dart';
import 'package:jeeves/sync/host/sync_host_service.dart';
import 'package:jeeves/sync/merge_strategy.dart';
import 'package:jeeves/sync/sync_database.dart';

import '../harness/resolution_columns.dart';
import 'host_harness.dart';

const String _outcomeA = '3f2d1c4e-5a6b-4c8d-9e0f-1a2b3c4d5e6f';
const String _outcomeB = '4a3e2d5f-6b7c-4d9e-8f01-2b3c4d5e6f70';

/// A member id no op on this device ever carries — the one a session that is
/// never restored leaves behind.
const String _memberIdHex = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';

void main() {
  test('a delete failing after an earlier row merged still hands the bridge '
      'both changes that merged', () async {
    final device = HostDevice.open('a');
    addTearDown(device.close);
    // A member id, so the writes are changes that still need an op: the bridge
    // is handed the record of such a change, not the merge itself.
    await device.domain.ensureDeviceClockIdentity();
    await device.domain.customStatement(
      'UPDATE device_clock_identity SET enrolled_member_id_hex = ?',
      [_memberIdHex],
    );
    // No host attached yet: both writes wait in the outbox.
    await device.domain.todoDao
        .insertOutcome(id: _outcomeA, title: 'First', userId: 'u');
    await device.domain.todoDao
        .insertOutcome(id: _outcomeB, title: 'Second', userId: 'u');
    final ids = (await device.domain
            .customSelect('SELECT id FROM pending_changes ORDER BY id')
            .get())
        .map((row) => row.read<int>('id'))
        .toList();
    expect(ids.length, greaterThanOrEqualTo(2));
    await device.domain.customStatement(
      'CREATE TRIGGER fail_second_delete BEFORE DELETE ON pending_changes '
      'WHEN OLD.id = ${ids[1]} BEGIN SELECT RAISE(ABORT, \'boom\'); END',
    );

    final notified = <Change>[];
    final host = SyncHostService(
        sync: device.sync, domain: device.domain, clock: device.clock)
      ..localChangeListener = (changes) async => notified.addAll(changes);
    await expectLater(host.start(), throwsA(anything));

    // Both changes merged before the delete failed, so both were recorded and
    // both were handed over.
    expect(notified.map((c) => c.entityId),
        orderedEquals([_outcomeA, _outcomeB]));

    // The row that could not be deleted replays on the next drain.
    await device.domain.customStatement('DROP TRIGGER fail_second_delete');
    await host.drain();
    expect(notified.where((c) => c.entityId == _outcomeB), hasLength(1),
        reason: 'the replay is the same change, so it is handed once');
    expect(
        await device.domain.customSelect('SELECT 1 FROM pending_changes').get(),
        isEmpty);
  });

  test('a remote batch with one key-less preference merges and projects the rest',
      () async {
    final device = HostDevice.open('a');
    addTearDown(device.close);
    final host = await device.startHost();
    Hlc at(int counter) => Hlc(1700000000000, counter, 'b' * 32);
    Change preference(String id, {required bool withKey}) => Change(
          collection: userPreferencesCollection,
          entityId: id,
          fields: {
            if (withKey) preferenceKeyField: ClockedValue('theme', at(1)),
            preferenceValueField: ClockedValue('dark', at(1)),
          },
        );

    await host.applyRemote('relay', [
      preference('p1', withKey: true),
      preference('p2', withKey: false),
      preference('p3', withKey: true),
    ]);

    final merged = await device.sync
        .customSelect('SELECT DISTINCT entity_id FROM reduced_fields ORDER BY 1')
        .get();
    expect(merged.map((r) => r.read<String>('entity_id')), ['p1', 'p3']);
  });

  test('a v9 sync store upgrades through v10 and keeps every merge-state row',
      () async {
    final directory = Directory.systemTemp.createTempSync('sync-v9-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/sync.sqlite');

    final seed = SyncDatabase(NativeDatabase(file));
    await seed.customStatement('DROP TABLE change_sequence');
    await seed.customStatement('DROP TABLE plugin_cursors');
    // A v9 store predates the decision columns, and opening it at the current
    // schema runs every later step: v14 and v15 add columns, so the fixture
    // has to take them away too.
    await dropColumnsAddedAfter(seed, 9);
    await seed.customStatement(
        "INSERT INTO reduced_fields (collection, entity_id, field, value_json) "
        "VALUES ('todos', 't1', 'title', '\"Ship it\"')");
    await seed.customStatement(
        "INSERT INTO field_clocks (collection, entity_id, field, wall_ms, counter, member_id_hex) "
        "VALUES ('todos', 't1', 'title', 5, 0, '${'a' * 32}')");
    await seed.customStatement(
        "INSERT INTO row_tombstones (collection, entity_id, wall_ms, counter, member_id_hex) "
        "VALUES ('todos', 't2', 6, 1, '${'a' * 32}')");
    await seed.customStatement('PRAGMA user_version = 9');
    await seed.close();

    final upgraded = SyncDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    final tables = (await upgraded
            .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
            .get())
        .map((r) => r.read<String>('name'));
    expect(tables, containsAll(['change_sequence', 'plugin_cursors']));
    final field = await upgraded
        .customSelect('SELECT value_json FROM reduced_fields').getSingle();
    expect(field.read<String>('value_json'), '"Ship it"');
    expect(await upgraded.customSelect('SELECT 1 FROM field_clocks').get(),
        hasLength(1));
    expect(await upgraded.customSelect('SELECT 1 FROM row_tombstones').get(),
        hasLength(1));
  });

  test('a v11 sync store upgrades through v12 and keeps every row', () async {
    final directory = Directory.systemTemp.createTempSync('sync-v11-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/sync.sqlite');

    final seed = SyncDatabase(NativeDatabase(file));
    await seed.customStatement('DROP TABLE unauthored_changes');
    // A v11 store predates the decision columns, and opening it at the current
    // schema runs every later step: v14 and v15 add columns, so the fixture
    // has to take them away too.
    await dropColumnsAddedAfter(seed, 11);
    await seed.into(seed.opLog).insert(
          OpLogCompanion.insert(
            seq: 1,
            workspaceId: 'w1',
            envelope: Uint8List.fromList([1, 2, 3]),
            opId: 'op-1',
            authorMemberId: 'a' * 32,
            authorSeq: 1,
            receivedAt: DateTime.utc(2026, 1, 2),
          ),
        );
    await seed.into(seed.outbox).insert(
          OutboxCompanion.insert(
            workspaceId: 'w1',
            opId: 'op-1',
            authorSeq: 1,
            envelope: Uint8List.fromList([1, 2, 3]),
            capturedAt: DateTime.utc(2026, 1, 2),
          ),
        );
    await seed.customStatement(
        "INSERT INTO reduced_fields (collection, entity_id, field, value_json) "
        "VALUES ('todos', 't1', 'title', '\"Ship it\"')");
    await seed.customStatement(
        "INSERT INTO field_clocks (collection, entity_id, field, wall_ms, counter, member_id_hex) "
        "VALUES ('todos', 't1', 'title', 5, 0, '${'a' * 32}')");
    await seed.customStatement(
        "INSERT INTO row_tombstones (collection, entity_id, wall_ms, counter, member_id_hex) "
        "VALUES ('todos', 't2', 6, 1, '${'a' * 32}')");
    // What the store read back before the upgrade is what it must read back
    // after it: the same library, the same rows, unchanged.
    final loggedBefore = await seed.select(seed.opLog).getSingle();
    final outboxedBefore = await seed.select(seed.outbox).getSingle();
    await seed.customStatement('PRAGMA user_version = 11');
    await seed.close();

    final upgraded = SyncDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    final tables = (await upgraded
            .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
            .get())
        .map((r) => r.read<String>('name'));
    expect(tables, contains('unauthored_changes'));
    expect(
        await upgraded.customSelect('SELECT 1 FROM unauthored_changes').get(),
        isEmpty,
        reason: 'a device that predates the table had nothing recorded');

    final logged = await upgraded.select(upgraded.opLog).getSingle();
    expect(logged.seq, loggedBefore.seq);
    expect(logged.opId, loggedBefore.opId);
    expect(logged.envelope, loggedBefore.envelope);
    expect(logged.receivedAt, loggedBefore.receivedAt);
    final outboxed = await upgraded.select(upgraded.outbox).getSingle();
    expect(outboxed.opId, outboxedBefore.opId);
    expect(outboxed.envelope, outboxedBefore.envelope);
    expect(outboxed.capturedAt, outboxedBefore.capturedAt);
    final field = await upgraded
        .customSelect('SELECT value_json FROM reduced_fields').getSingle();
    expect(field.read<String>('value_json'), '"Ship it"');
    expect(await upgraded.customSelect('SELECT 1 FROM field_clocks').get(),
        hasLength(1));
    expect(await upgraded.customSelect('SELECT 1 FROM row_tombstones').get(),
        hasLength(1));
  });
}
