/// The sync host, end to end, with no op log and no server.
///
/// Real stores, real DAOs, real merge — the only stand-in is the plugin, a relay
/// over an in-memory list. A device here is what every device is after the host
/// exists and before any plugin is attached.
@TestOn('!browser')
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/host/change.dart';

import '../harness/reduced_state.dart';
import 'host_harness.dart';

const String _userId = 'host-journey-user';
const String _outcomeA = '3f2d1c4e-5a6b-4c8d-9e0f-1a2b3c4d5e6f';
const String _outcomeB = '4a3e2d5f-6b7c-4d9e-8f01-2b3c4d5e6f70';

Future<List<Map<String, Object?>>> _todoRows(HostDevice device) async {
  final rows = await device.domain
      .customSelect('SELECT id, title, notes, energy_level FROM todos ORDER BY id')
      .get();
  return [for (final row in rows) row.data];
}

Future<int> _count(HostDevice device, String table) async =>
    (await device.domain.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle())
        .read<int>('c');

void main() {
  group('two devices converge through a plugin', () {
    test('creates, concurrent edits, a deletion and a non-LWW preference', () async {
      final relay = <({String origin, Change change})>[];
      final a = HostDevice.open('a');
      final b = HostDevice.open('b');
      addTearDown(a.close);
      addTearDown(b.close);
      final hostA = await a.startHost();
      final hostB = await b.startHost();
      final pluginA = RelayPlugin('relay', relay)..origin = 'a';
      final pluginB = RelayPlugin('relay', relay)..origin = 'b';
      await hostA.attach(pluginA);
      await hostB.attach(pluginB);

      Future<void> sync() async {
        await hostA.deliverAll();
        await hostB.deliverAll();
        await pluginA.pull();
        await pluginB.pull();
        await hostA.deliverAll();
        await hostB.deliverAll();
      }

      // Creates on both sides.
      await a.domain.todoDao
          .insertOutcome(id: _outcomeA, title: 'From A', userId: _userId);
      await b.domain.todoDao
          .insertOutcome(id: _outcomeB, title: 'From B', userId: _userId);
      await sync();
      expect(await _todoRows(b), await _todoRows(a));
      expect((await _todoRows(a)).length, 2);

      // Concurrent edits: different fields of one entity, then one field.
      a.wall.advance();
      await a.domain.todoDao.updateFields(_outcomeA, notes: 'notes from A');
      b.wall.advance();
      await b.domain.todoDao.updateFields(_outcomeA, energyLevel: 'high');
      a.wall.advance(2000);
      await a.domain.todoDao.updateFields(_outcomeA, title: 'A title');
      b.wall.advance(5000);
      await b.domain.todoDao.updateFields(_outcomeA, title: 'B title (later)');
      // A deletion on one side, a preference on each.
      b.wall.advance();
      await b.domain.todoDao.deleteOutcome(_outcomeB);
      await a.domain.userPreferencesDao
          .set(_userId, 'nudge_snoozed_until', jsonEncode('2026-03-01T00:00:00.000Z'));
      await b.domain.userPreferencesDao
          .set(_userId, 'nudge_snoozed_until', jsonEncode('2026-02-01T00:00:00.000Z'));
      await sync();

      expect(await canonicalReducedState(b.sync), await canonicalReducedState(a.sync));
      expect(await _todoRows(b), await _todoRows(a));
      final rowsA = await _todoRows(a);
      expect(rowsA.single['id'], _outcomeA,
          reason: 'the deleted Outcome is gone on both devices');
      expect(rowsA.single['title'], 'B title (later)');
      expect(rowsA.single['notes'], 'notes from A');
      expect(rowsA.single['energy_level'], 'high');
      expect(await canonicalReducedState(a.sync), contains('2026-03-01'),
          reason: 'the later instant wins a max-timestamp preference on both');
    });
  });

  group('the outbox', () {
    test('a throwing body leaves neither a domain row nor a change', () async {
      final device = HostDevice.open('a');
      addTearDown(device.close);

      await expectLater(
        device.domain.capturing(() async {
          await device.domain.todoDao
              .insertOutcome(id: _outcomeA, title: 'Doomed', userId: _userId);
          throw StateError('abandoned');
        }),
        throwsStateError,
      );

      expect(await _count(device, 'todos'), 0);
      expect(await _count(device, 'pending_changes'), 0);
    });

    test('a write committed before any host exists is clocked, and the clock '
        'survives the later drain', () async {
      final device = HostDevice.open('a');
      addTearDown(device.close);

      await device.domain.todoDao
          .insertOutcome(id: _outcomeA, title: 'Early', userId: _userId);

      final node = (await device.domain
              .customSelect('SELECT device_node_id FROM device_clock_identity')
              .getSingle())
          .read<String>('device_node_id');
      expect(node, matches(RegExp(r'^[0-9a-f]{32}$')));
      final staged = await device.domain
          .customSelect('SELECT change_json FROM pending_changes')
          .get();
      expect(staged, isNotEmpty);
      final stagedChanges = [
        for (final row in staged)
          Change.fromJson(
              (jsonDecode(row.read<String>('change_json')) as Map).cast<String, Object?>()),
      ];
      final titleClock = stagedChanges
          .firstWhere((change) => change.entityId == _outcomeA)
          .fields['title']!
          .hlc;
      expect(titleClock.memberIdHex, node);

      await device.startHost();

      expect(await _count(device, 'pending_changes'), 0);
      final reduced = await device.sync
          .customSelect("SELECT wall_ms, counter, member_id_hex FROM field_clocks "
              "WHERE entity_id = ? AND field = 'title'",
              variables: [Variable<String>(_outcomeA)])
          .getSingle();
      expect([
        reduced.read<int>('wall_ms'),
        reduced.read<int>('counter'),
        reduced.read<String>('member_id_hex'),
      ], titleClock.toJson());
    });

    test('an enrolled device stamps with its member id, from the domain store alone',
        () async {
      final device = HostDevice.open('a');
      addTearDown(device.close);
      const memberHex = 'abababababababababababababababab';
      await device.domain.ensureDeviceClockIdentity();
      await device.domain.customStatement(
          'UPDATE device_clock_identity SET enrolled_member_id_hex = ?', [memberHex]);

      await device.domain.todoDao
          .insertOutcome(id: _outcomeA, title: 'Cold start', userId: _userId);

      final staged =
          await device.domain.customSelect('SELECT change_json FROM pending_changes').get();
      for (final row in staged) {
        final change = Change.fromJson(
            (jsonDecode(row.read<String>('change_json')) as Map).cast<String, Object?>());
        expect(change.highestClock!.memberIdHex, memberHex);
      }
    });

    test('a kill before the drain replays on the next start', () async {
      final directory = Directory.systemTemp.createTempSync('host-kill-');
      addTearDown(() => directory.deleteSync(recursive: true));

      final first = HostDevice.open('a', directory: directory);
      await first.domain.todoDao
          .insertOutcome(id: _outcomeA, title: 'Survives', userId: _userId);
      expect(await _count(first, 'pending_changes'), greaterThan(0));
      await first.close();

      final second = HostDevice.open('a', directory: directory);
      addTearDown(second.close);
      expect(await _count(second, 'pending_changes'), greaterThan(0),
          reason: 'the rows survived the process');
      await second.startHost();

      expect(await _count(second, 'pending_changes'), 0);
      final title = await second.sync
          .customSelect("SELECT value_json FROM reduced_fields "
              "WHERE entity_id = ? AND field = 'title'",
              variables: [Variable<String>(_outcomeA)])
          .getSingle();
      expect(jsonDecode(title.read<String>('value_json')), 'Survives');
    });

    test('a fault between the sync commit and the outbox delete leaves one '
        'sequence entry', () async {
      final device = HostDevice.open('a');
      addTearDown(device.close);
      final host = await device.startHost();
      await host.attach(RelayPlugin('relay', []));

      await device.domain.todoDao
          .insertOutcome(id: _outcomeA, title: 'Once', userId: _userId);
      final sequenceBefore =
          (await device.sync.customSelect('SELECT COUNT(*) AS c FROM change_sequence').getSingle())
              .read<int>('c');
      expect(sequenceBefore, greaterThan(0));

      // Put back a row the drain had already merged — what a crash between the
      // two commits leaves behind: the same change_id, the same clocks.
      final entries = await device.sync
          .customSelect('SELECT change_id, change_json FROM change_sequence')
          .get();
      for (final entry in entries) {
        await device.domain.customStatement(
          'INSERT INTO pending_changes (change_id, change_json) VALUES (?, ?)',
          [entry.read<String>('change_id'), entry.read<String>('change_json')],
        );
      }
      final stateBefore = await canonicalReducedState(device.sync);
      await host.drain();

      expect(await _count(device, 'pending_changes'), 0);
      expect(
          (await device.sync.customSelect('SELECT COUNT(*) AS c FROM change_sequence').getSingle())
              .read<int>('c'),
          sequenceBefore);
      expect(await canonicalReducedState(device.sync), stateBefore);
    });
  });

  group('delivery and cursors', () {
    test('an unacknowledged change is delivered again, across a host restart, '
        'and nothing is skipped', () async {
      final directory = Directory.systemTemp.createTempSync('host-redeliver-');
      addTearDown(() => directory.deleteSync(recursive: true));

      var device = HostDevice.open('a', directory: directory);
      var host = await device.startHost();
      final relay = <({String origin, Change change})>[];
      var plugin = RelayPlugin('relay', relay)
        ..origin = 'a'
        ..acknowledgeAtMost = 0;
      await host.attach(plugin);

      await device.domain.todoDao
          .insertOutcome(id: _outcomeA, title: 'One', userId: _userId);
      await device.domain.todoDao
          .insertOutcome(id: _outcomeB, title: 'Two', userId: _userId);
      await host.deliverAll();
      expect(await host.cursorOf('relay'), 0, reason: 'nothing acknowledged');
      final firstBatch = [
        for (final row in await device.sync
            .customSelect('SELECT sequence FROM change_sequence ORDER BY sequence')
            .get())
          row.read<int>('sequence'),
      ];
      expect(firstBatch.length, greaterThan(1));

      // Restart: a new host over the same stores, the same plugin id.
      await device.close();
      device = HostDevice.open('a', directory: directory);
      addTearDown(device.close);
      host = await device.startHost();
      plugin = RelayPlugin('relay', relay)
        ..origin = 'a'
        ..acknowledgeAtMost = 1;
      await host.attach(plugin);
      await host.deliverAll();

      expect(plugin.deliveries.first.map((c) => c.sequence).toList(), firstBatch,
          reason: 'the same changes come again after the restart');
      // It took only the first of each batch it was handed; the host kept asking
      // until nothing further advanced.
      final delivered = [for (final batch in plugin.deliveries) ...batch.map((c) => c.sequence)];
      expect(delivered.toSet(), containsAll(firstBatch));
      final all = relay.map((e) => e.change.entityId).toList();
      expect(all, containsAll([_outcomeA, _outcomeB]));
    });

    test('an acknowledgement beyond what was delivered is clamped', () async {
      final device = HostDevice.open('a');
      addTearDown(device.close);
      final host = await device.startHost();
      final plugin = _OverAcknowledgingPlugin();
      await host.attach(plugin);

      await device.domain.todoDao
          .insertOutcome(id: _outcomeA, title: 'One', userId: _userId);
      await host.deliverAll();

      final highestDelivered =
          plugin.deliveries.expand((batch) => batch).map((c) => c.sequence).reduce(
              (a, b) => a > b ? a : b);
      expect(await host.cursorOf('over'), highestDelivered);
    });

    test('a failing plugin does not move its cursor, and a change is never '
        'handed back to its own source', () async {
      final device = HostDevice.open('a');
      addTearDown(device.close);
      final host = await device.startHost();
      final plugin = RelayPlugin('relay', [])
        ..origin = 'a'
        ..failing = true;
      await host.attach(plugin);

      await device.domain.todoDao
          .insertOutcome(id: _outcomeA, title: 'One', userId: _userId);
      await host.deliverAll();
      expect(await host.cursorOf('relay'), 0);
      expect(plugin.deliveries, isNotEmpty);

      plugin.failing = false;
      await host.deliverAll();
      expect(await host.cursorOf('relay'), greaterThan(0));

      // A remote change from this very plugin is merged but not sent back.
      final before = plugin.deliveries.length;
      await host.applyRemote('relay', [
        Change(
          collection: 'todos',
          entityId: _outcomeB,
          fields: {'title': ClockedValue('Remote', host.mintClock())},
        ),
      ]);
      await host.deliverAll();
      expect(
          plugin.deliveries.skip(before).expand((b) => b).map((c) => c.change.entityId),
          isNot(contains(_outcomeB)));
    });

    test('no plugin attached means nothing is appended to the sequence', () async {
      final device = HostDevice.open('a');
      addTearDown(device.close);
      await device.startHost();

      await device.domain.todoDao
          .insertOutcome(id: _outcomeA, title: 'One', userId: _userId);

      expect(
          (await device.sync.customSelect('SELECT COUNT(*) AS c FROM change_sequence').getSingle())
              .read<int>('c'),
          0);
    });
  });
}

class _OverAcknowledgingPlugin extends RelayPlugin {
  _OverAcknowledgingPlugin() : super('over', []);

  @override
  Future<int> deliver(List<SequencedChange> changes) async {
    deliveries.add(changes);
    return changes.last.sequence + 100;
  }
}
