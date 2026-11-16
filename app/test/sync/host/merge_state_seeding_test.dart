/// The seeding pass: domain rows that predate the sync host reach merge state
/// once, at the floor clock, without a write to the domain store or an op.
@TestOn('!browser')
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/host/change.dart';
import 'package:jeeves/sync/host/merge_core.dart';
import 'package:jeeves/sync/host/merge_state_seeder.dart';
import 'package:jeeves/sync/host/sync_host_service.dart';
import 'package:jeeves/sync/sync_database.dart';

import '../harness/reduced_state.dart';
import 'host_harness.dart';

const String _userId = 'seeding-user';
const String _outcomeA = '3f2d1c4e-5a6b-4c8d-9e0f-1a2b3c4d5e6f';
const String _outcomeB = '4a3e2d5f-6b7c-4d9e-8f01-2b3c4d5e6f70';
const String _preferenceKey = 'nudge_snoozed_until';

/// Rows that exist before the host does: written through the DAOs, then the
/// outbox entries those writes staged are dropped, so merge state has never
/// heard of them — the shape of a device upgrading to the host.
Future<void> _writeRowsThatPredateTheHost(HostDevice device) async {
  await device.domain.todoDao
      .insertOutcome(id: _outcomeA, title: 'Old A', userId: _userId);
  await device.domain.todoDao
      .insertOutcome(id: _outcomeB, title: 'Old B', userId: _userId);
  await device.domain.userPreferencesDao
      .set(_userId, _preferenceKey, jsonEncode('2026-03-01T00:00:00.000Z'));
  await device.domain.customStatement('DELETE FROM pending_changes');
}

Future<Map<String, Map<String, Object?>>> _snapshotValues(
    SyncHostService host) async {
  final out = <String, Map<String, Object?>>{};
  await for (final change in host.snapshot()) {
    out['${change.collection}/${change.entityId}'] = {
      for (final field in change.fields.entries) field.key: field.value.value,
    };
  }
  return out;
}

final RegExp _instant = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}');

Map<String, Map<String, Object?>> _withoutInstants(
        Map<String, Map<String, Object?>> snapshot) =>
    {
      for (final entity in snapshot.entries)
        entity.key: {
          for (final field in entity.value.entries)
            field.key: field.value is String &&
                    _instant.hasMatch(field.value as String)
                ? '<instant>'
                : field.value,
        },
    };

Future<List<Map<String, Object?>>> _domainTable(
    HostDevice device, String table) async {
  final rows =
      await device.domain.customSelect('SELECT * FROM $table ORDER BY id').get();
  return [for (final row in rows) row.data];
}

Future<int> _count(dynamic database, String table) async =>
    (await database.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle())
        .read<int>('c');

void main() {
  test('the floor clock round-trips and loses to every real clock', () {
    final node = 'a' * 32;
    final floor = Hlc(0, 0, node);
    expect(Hlc.fromJson(floor.toJson()), floor);
    expect(floor.toJson(), [0, 0, node]);
    expect(floor < Hlc(1, 0, '0' * 32), isTrue);
    expect(floor > Hlc(0, 0, '0' * 32), isTrue, reason: 'only the node id breaks a tie');
    expect(Change.fromJson(Change(
      collection: 'todos',
      entityId: 'x',
      fields: {'title': ClockedValue('t', floor)},
    ).toJson()).fields['title']!.hlc, floor);
  });

  group('the walk', () {
    test('puts every pre-existing entity in the snapshot, touching nothing else',
        () async {
      final device = HostDevice.open('a');
      addTearDown(device.close);
      await _writeRowsThatPredateTheHost(device);
      final todosBefore = await _domainTable(device, 'todos');
      final preferencesBefore = await _domainTable(device, 'user_preferences');

      final host = await device.startHost();
      await host.ensureMergeStateSeeded();

      final snapshot = await _snapshotValues(host);
      expect(snapshot.keys.where((key) => key.startsWith('todos/')),
          unorderedEquals(['todos/$_outcomeA', 'todos/$_outcomeB']));
      expect(snapshot['todos/$_outcomeA']!['title'], 'Old A');
      expect(snapshot.keys.where((key) => key.startsWith('user_preferences/')),
          hasLength(1));

      // Every seeded field carries the floor clock under the device node id.
      final clocks = await device.sync.select(device.sync.fieldClocks).get();
      expect(clocks, isNotEmpty);
      for (final clock in clocks) {
        expect([clock.wallMs, clock.counter, clock.memberIdHex],
            [0, 0, host.deviceNodeId]);
      }

      // No domain write, no op, no tombstone.
      expect(await _domainTable(device, 'todos'), todosBefore);
      expect(await _domainTable(device, 'user_preferences'), preferencesBefore);
      expect(await _count(device.domain, 'pending_changes'), 0);
      expect(await _count(device.sync, 'change_sequence'), 0);
      expect(await _count(device.sync, 'row_tombstones'), 0);
      expect(await _count(device.sync, 'merge_state_seeding'), 1);
    });

    test('a second walk changes nothing, and the marker stops a walk at all',
        () async {
      final device = HostDevice.open('a');
      addTearDown(device.close);
      await _writeRowsThatPredateTheHost(device);
      final host = await device.startHost();
      await host.ensureMergeStateSeeded();
      final afterFirst = await canonicalReducedState(device.sync);

      final seeder = MergeStateSeeder(
        sync: device.sync,
        domain: device.domain,
        core: MergeCore(device.sync),
        deviceNodeId: host.deviceNodeId,
      );
      expect(await seeder.runIfIncomplete(), isNull, reason: 'marker is set');

      // A row inserted behind the host's back is not picked up once marked.
      device.capture.detach();
      await device.domain.todoDao
          .insertOutcome(id: 'late', title: 'Late', userId: _userId);
      await device.domain.customStatement('DELETE FROM pending_changes');
      device.capture.attach(host);
      expect(await seeder.runIfIncomplete(), isNull);
      expect(await canonicalReducedState(device.sync), afterFirst);

      // Without the marker the walk still finds nothing existing to change.
      await device.sync.customStatement('DELETE FROM merge_state_seeding');
      final rerun = await seeder.run();
      expect(rerun.insertedFieldCount, greaterThan(0),
          reason: 'only the late row is new');
      final snapshot = await _snapshotValues(host);
      expect(snapshot, contains('todos/late'));
      await device.sync.customStatement('DELETE FROM merge_state_seeding');
      final afterSecond = await canonicalReducedState(device.sync);
      final third = await seeder.run();
      expect(third.insertedFieldCount, 0);
      expect(await canonicalReducedState(device.sync), afterSecond);
    });

    test('an entity already in merge state keeps its clocks and gains the rest',
        () async {
      final device = HostDevice.open('a');
      addTearDown(device.close);
      await _writeRowsThatPredateTheHost(device);
      final host = await device.startHost();
      // A real edit after the upgrade, before the walk.
      device.wall.advance();
      await device.domain.todoDao.updateFields(_outcomeA, title: 'Edited');
      await host.drain();
      final editedClock = await (device.sync.select(device.sync.fieldClocks)
            ..where((row) =>
                row.entityId.equals(_outcomeA) & row.field.equals('title')))
          .getSingle();
      expect(editedClock.wallMs, greaterThan(0));

      await host.ensureMergeStateSeeded();

      final after = await (device.sync.select(device.sync.fieldClocks)
            ..where((row) =>
                row.entityId.equals(_outcomeA) & row.field.equals('title')))
          .getSingle();
      expect([after.wallMs, after.counter, after.memberIdHex],
          [editedClock.wallMs, editedClock.counter, editedClock.memberIdHex]);
      final snapshot = await _snapshotValues(host);
      expect(snapshot['todos/$_outcomeA']!['title'], 'Edited');
      expect(snapshot['todos/$_outcomeA']!, contains('user_id'),
          reason: 'the fields the edit did not touch were filled in');
    });

    test('a real write beats the seed, whichever lands first', () async {
      final device = HostDevice.open('a');
      addTearDown(device.close);
      await _writeRowsThatPredateTheHost(device);
      final host = await device.startHost();
      await host.ensureMergeStateSeeded();
      device.wall.advance();
      await device.domain.todoDao.updateFields(_outcomeB, title: 'After seed');
      await host.drain();
      expect((await _snapshotValues(host))['todos/$_outcomeB']!['title'],
          'After seed');
      await device.domain.todoDao.deleteOutcome(_outcomeB);
      await host.drain();
      // The delete wins over the seeded fields: the entity carries a tombstone.
      expect(await _count(device.sync, 'row_tombstones'), 1);
      final deleted = await host.snapshot().firstWhere(
          (change) => change.entityId == _outcomeB);
      expect(deleted.tombstone, isNotNull);
    });

    test('a walk cut short and restarted ends where an uninterrupted one does',
        () async {
      final interrupted = HostDevice.open('a');
      final control = HostDevice.open('b');
      addTearDown(interrupted.close);
      addTearDown(control.close);
      await _writeRowsThatPredateTheHost(interrupted);
      await _writeRowsThatPredateTheHost(control);
      final interruptedHost = await interrupted.startHost();
      final controlHost = await control.startHost();

      // Fail the walk part-way: the first collection's chunk lands, a later
      // one does not.
      await interrupted.sync.customStatement(
          'CREATE TRIGGER cut_short BEFORE INSERT ON field_clocks '
          "WHEN NEW.collection = 'user_preferences' "
          "BEGIN SELECT RAISE(ABORT, 'boom'); END");
      await expectLater(interruptedHost.ensureMergeStateSeeded(), throwsA(anything));
      expect(await _count(interrupted.sync, 'merge_state_seeding'), 0,
          reason: 'a failed walk leaves the marker unset');
      expect(await _count(interrupted.sync, 'field_clocks'), greaterThan(0),
          reason: 'what landed before the failure stays');

      await interrupted.sync.customStatement('DROP TRIGGER cut_short');
      await interruptedHost.ensureMergeStateSeeded();
      await controlHost.ensureMergeStateSeeded();

      // The two devices wrote their rows at different instants, so compare the
      // shape and the non-instant values; instants are checked by the clocks.
      expect(_withoutInstants(await _snapshotValues(interruptedHost)),
          _withoutInstants(await _snapshotValues(controlHost)));
      expect(await _count(interrupted.sync, 'merge_state_seeding'), 1);
    });
  });

  group('attach', () {
    test('hands a plugin a complete snapshot', () async {
      final device = HostDevice.open('a');
      addTearDown(device.close);
      await _writeRowsThatPredateTheHost(device);
      final host = await device.startHost();
      final plugin = RelayPlugin('relay', []);
      await host.attach(plugin);
      final keys = (await _snapshotValues(host)).keys;
      expect(keys, contains('todos/$_outcomeA'));
      expect(keys, contains('todos/$_outcomeB'));
    });

    test('a failing walk fails attach, records no cursor, and local writes drain',
        () async {
      final device = HostDevice.open('a');
      addTearDown(device.close);
      await _writeRowsThatPredateTheHost(device);
      final host = await device.startHost();
      await device.sync.customStatement(
          'CREATE TRIGGER no_seed BEFORE INSERT ON field_clocks '
          "WHEN NEW.wall_ms = 0 BEGIN SELECT RAISE(ABORT, 'boom'); END");

      await expectLater(host.attach(RelayPlugin('relay', [])), throwsA(anything));
      expect(await host.cursorOf('relay'), isNull);

      device.wall.advance();
      await device.domain.todoDao
          .insertOutcome(id: 'fresh', title: 'Fresh', userId: _userId);
      await host.drain();
      expect(await _count(device.domain, 'pending_changes'), 0);
      expect((await _snapshotValues(host)), contains('todos/fresh'));
    });

    test('two upgraded devices exchange snapshots and agree', () async {
      final relay = <({String origin, Change change})>[];
      final a = HostDevice.open('a');
      final b = HostDevice.open('b');
      addTearDown(a.close);
      addTearDown(b.close);
      await _writeRowsThatPredateTheHost(a);
      await b.domain.todoDao
          .insertOutcome(id: 'only-b', title: 'Only B', userId: _userId);
      await b.domain.userPreferencesDao
          .set(_userId, _preferenceKey, jsonEncode('2026-02-01T00:00:00.000Z'));
      await b.domain.customStatement('DELETE FROM pending_changes');
      final hostA = await a.startHost();
      final hostB = await b.startHost();
      final pluginA = RelayPlugin('relay', relay)..origin = 'a';
      final pluginB = RelayPlugin('relay', relay)..origin = 'b';
      await hostA.attach(pluginA);
      await hostB.attach(pluginB);
      await for (final change in hostA.snapshot()) {
        relay.add((origin: 'a', change: change));
      }
      await for (final change in hostB.snapshot()) {
        relay.add((origin: 'b', change: change));
      }
      await pluginA.pull();
      await pluginB.pull();

      final valuesA = await _snapshotValues(hostA);
      expect(valuesA.keys, contains('todos/only-b'));
      expect(valuesA.keys, contains('todos/$_outcomeA'));
      expect(valuesA, await _snapshotValues(hostB),
          reason: 'both devices hold the union and agree on the shared key');
    });
  });

  test('a v10 sync store upgrades to v11 and keeps every merge-state row',
      () async {
    final directory = Directory.systemTemp.createTempSync('sync-v10-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/sync.sqlite');

    final seed = SyncDatabase(NativeDatabase(file));
    await seed.customStatement('DROP TABLE merge_state_seeding');
    await seed.customStatement(
        "INSERT INTO reduced_fields (collection, entity_id, field, value_json) "
        "VALUES ('todos', 't1', 'title', '\"Ship it\"')");
    await seed.customStatement(
        "INSERT INTO field_clocks (collection, entity_id, field, wall_ms, counter, member_id_hex) "
        "VALUES ('todos', 't1', 'title', 5, 0, '${'a' * 32}')");
    await seed.customStatement('PRAGMA user_version = 10');
    await seed.close();

    final upgraded = SyncDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    expect(await _count(upgraded, 'merge_state_seeding'), 0,
        reason: 'the table exists and the device has not walked');
    final field = await upgraded
        .customSelect('SELECT value_json FROM reduced_fields').getSingle();
    expect(field.read<String>('value_json'), '"Ship it"');
    expect(await _count(upgraded, 'field_clocks'), 1);
  });
}
