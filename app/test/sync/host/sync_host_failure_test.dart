/// Failures partway through a drain or a remote batch must not lose what
/// already merged, and a v9 sync store must upgrade without losing merge state.
@TestOn('!browser')
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/collection_codecs.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/host/change.dart';
import 'package:jeeves/sync/host/sync_host_service.dart';
import 'package:jeeves/sync/merge_strategy.dart';
import 'package:jeeves/sync/sync_database.dart';

import '../harness/v12_columns.dart';
import 'host_harness.dart';

const String _outcomeA = '3f2d1c4e-5a6b-4c8d-9e0f-1a2b3c4d5e6f';
const String _outcomeB = '4a3e2d5f-6b7c-4d9e-8f01-2b3c4d5e6f70';

void main() {
  test('a delete failing after an earlier row merged still notifies the bridge',
      () async {
    final device = HostDevice.open('a');
    addTearDown(device.close);
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

    expect(notified.map((c) => c.entityId), contains(_outcomeA));
    expect(notified.map((c) => c.entityId), isNot(contains(_outcomeB)));

    // The row that could not be deleted replays and is notified on the next drain.
    await device.domain.customStatement('DROP TRIGGER fail_second_delete');
    await host.drain();
    expect(notified.map((c) => c.entityId), contains(_outcomeB));
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

  test('a v9 sync store upgrades to v10 and keeps every merge-state row', () async {
    final directory = Directory.systemTemp.createTempSync('sync-v9-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/sync.sqlite');

    final seed = SyncDatabase(NativeDatabase(file));
    await seed.customStatement('DROP TABLE change_sequence');
    await seed.customStatement('DROP TABLE plugin_cursors');
    // A v9 store predates the decision columns, and opening it at the current
    // schema runs every later step: v12 adds columns, so the fixture has to
    // take them away too.
    await dropV12Columns(seed);
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
}
