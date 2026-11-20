/// The op-log folder plugin, end to end, with no server.
///
/// Two or three real devices — both stores, real DAOs, real host, real signing —
/// sharing one real temporary directory. One group per acceptance criterion.
@TestOn('!browser')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/folder/folder_metadata.dart';
import 'package:jeeves/sync/folder/segment_format.dart';
import 'package:jeeves/sync/host/change.dart';
import 'package:jeeves/sync/sync_database.dart';

import '../harness/reduced_state.dart';
import '../host/host_harness.dart';
import '../host/pre_host_rows.dart';
import 'folder_harness.dart';

const String _userId = 'folder-journey-user';
const String _outcomeA = '3f2d1c4e-5a6b-4c8d-9e0f-1a2b3c4d5e6f';
const String _outcomeB = '4a3e2d5f-6b7c-4d9e-8f01-2b3c4d5e6f70';
const String _outcomeC = '5b4f3e60-7c8d-4eaf-9012-3c4d5e6f7081';

Future<List<Map<String, Object?>>> _todoRows(HostDevice device) async {
  final rows = await device.domain
      .customSelect('SELECT id, title, notes, energy_level FROM todos ORDER BY id')
      .get();
  return [for (final row in rows) row.data];
}

Future<List<IntegrityAlarmRow>> _alarms(FolderDevice device) =>
    device.device.sync.select(device.device.sync.integrityAlarms).get();

Future<({Directory directory, FolderDevice a, FolderDevice b})> _pair() async {
  final directory = Directory.systemTemp.createTempSync('folder-sync-');
  addTearDown(() => directory.deleteSync(recursive: true));
  final a = await FolderDevice.open('a', directory);
  final b = await FolderDevice.open('b', directory);
  addTearDown(a.close);
  addTearDown(b.close);
  await a.bind();
  await b.bind();
  await a.pairWith(b);
  await b.pairWith(a);
  await a.attach();
  await b.attach();
  return (directory: directory, a: a, b: b);
}

Future<void> _exchange(FolderDevice a, FolderDevice b) async {
  await propagate(a, b);
  await propagate(b, a);
  await propagate(a, b);
}

void main() {
  group('criterion 2: two devices converge with no server running', () {
    test('creates, concurrent edits, a deletion and a non-LWW preference', () async {
      final (:directory, :a, :b) = await _pair();

      await a.device.domain.todoDao
          .insertOutcome(id: _outcomeA, title: 'From A', userId: _userId);
      await b.device.domain.todoDao
          .insertOutcome(id: _outcomeB, title: 'From B', userId: _userId);
      await _exchange(a, b);
      expect(await _todoRows(b.device), await _todoRows(a.device));
      expect((await _todoRows(a.device)).length, 2);

      a.device.wall.advance();
      await a.device.domain.todoDao.updateFields(_outcomeA, notes: 'notes from A');
      b.device.wall.advance();
      await b.device.domain.todoDao.updateFields(_outcomeA, energyLevel: 'high');
      a.device.wall.advance(2000);
      await a.device.domain.todoDao.updateFields(_outcomeA, title: 'A title');
      b.device.wall.advance(5000);
      await b.device.domain.todoDao.updateFields(_outcomeA, title: 'B title (later)');
      b.device.wall.advance();
      await b.device.domain.todoDao.deleteOutcome(_outcomeB);
      await a.device.domain.userPreferencesDao
          .set(_userId, 'nudge_snoozed_until', jsonEncode('2026-03-01T00:00:00.000Z'));
      await b.device.domain.userPreferencesDao
          .set(_userId, 'nudge_snoozed_until', jsonEncode('2026-02-01T00:00:00.000Z'));
      await _exchange(a, b);

      expect(await canonicalReducedState(b.device.sync),
          await canonicalReducedState(a.device.sync));
      expect(await _todoRows(b.device), await _todoRows(a.device));
      final rows = await _todoRows(a.device);
      expect(rows.single['id'], _outcomeA);
      expect(rows.single['title'], 'B title (later)');
      expect(rows.single['notes'], 'notes from A');
      expect(rows.single['energy_level'], 'high');
      expect(await canonicalReducedState(a.device.sync), contains('2026-03-01'));
      expect(await _alarms(a), isEmpty);
      expect(await _alarms(b), isEmpty);
    });

    test('rows that existed before folder sync was turned on reach the other device',
        () async {
      final directory = Directory.systemTemp.createTempSync('folder-sync-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final deviceA = HostDevice.open('a');
      await writeRowInEveryCollection(deviceA.domain);
      final a = await FolderDevice.open('a', directory, existing: deviceA);
      final b = await FolderDevice.open('b', directory);
      addTearDown(a.close);
      addTearDown(b.close);
      await a.bind();
      await b.bind();
      await a.pairWith(b);
      await b.pairWith(a);
      await a.attach();
      await b.attach();

      await _exchange(a, b);
      expect(await _todoRows(b.device), await _todoRows(a.device));
      expect((await _todoRows(b.device)).single['id'], preHostOutcomeId);
      // Every pre-existing entity whose id the op format can carry (a canonical
      // UUID) reaches B with the same clocks; the fixture's few plain-string ids
      // are refused at the author, as no receiver would apply them.
      final carried = preHostEntityIdByCollection.entries
          .where((entry) => isCanonicalUuid(entry.value))
          .toList();
      expect(carried.length, greaterThan(5));
      for (final entry in carried) {
        final onA = await a.device.sync.customSelect(
            'SELECT field, value_json FROM reduced_fields WHERE collection = ? AND entity_id = ? ORDER BY field',
            variables: [Variable<String>(entry.key), Variable<String>(entry.value)]).get();
        final onB = await b.device.sync.customSelect(
            'SELECT field, value_json FROM reduced_fields WHERE collection = ? AND entity_id = ? ORDER BY field',
            variables: [Variable<String>(entry.key), Variable<String>(entry.value)]).get();
        expect(onA, isNotEmpty, reason: '${entry.key} is seeded on A');
        expect([for (final row in onB) row.data], [for (final row in onA) row.data],
            reason: '${entry.key} converged');
      }
    });

    test('a third device that joins later converges from the files alone', () async {
      final (:directory, :a, :b) = await _pair();
      await a.device.domain.todoDao
          .insertOutcome(id: _outcomeA, title: 'From A', userId: _userId);
      await b.device.domain.todoDao
          .insertOutcome(id: _outcomeB, title: 'From B', userId: _userId);
      await _exchange(a, b);

      final c = await FolderDevice.open('c', directory);
      addTearDown(c.close);
      await c.bind();
      await a.pairWith(c);
      await b.pairWith(c);
      await c.pairWith(a);
      await c.pairWith(b);
      await c.attach();

      expect(await _todoRows(c.device), await _todoRows(a.device));
      expect(await canonicalReducedState(c.device.sync),
          await canonicalReducedState(a.device.sync));
    });
  });

  group('criterion 1: every file has exactly one writing device', () {
    test('records are signed by the directory they sit in, and a peer never writes '
        "into another's files", () async {
      final (:directory, :a, :b) = await _pair();
      await a.device.domain.todoDao
          .insertOutcome(id: _outcomeA, title: 'From A', userId: _userId);
      await _exchange(a, b);
      final before = snapshotOps(directory, member: a.memberId);
      expect(before, isNotEmpty);

      b.device.wall.advance();
      await b.device.domain.todoDao.updateFields(_outcomeA, notes: 'from B');
      await _exchange(a, b);

      expect(snapshotOps(directory, member: a.memberId), before,
          reason: "B's activity leaves A's files byte for byte as they were");
      for (final device in [a, b]) {
        final member = MemberFile.parse(File(
                '${directory.path}/ops/${device.memberId}/$memberFileName')
            .readAsBytesSync());
        final envelopes = envelopesOf(directory, device.memberId);
        expect(envelopes, isNotEmpty);
        for (final envelope in envelopes) {
          expect(headerOf(envelope).authorMemberId, device.memberId);
          await verifyEnvelope(envelope, member.signPublicKey);
        }
      }
    });
  });

  group('criterion 3: a segment truncated mid-record', () {
    test('is read up to its last complete record and the rest follows when it arrives',
        () async {
      final (:directory, :a, :b) = await _pair();
      for (var index = 0; index < 3; index++) {
        a.device.wall.advance();
        await a.device.domain.todoDao.insertOutcome(
          id: const [_outcomeA, _outcomeB, _outcomeC][index],
          title: 'Outcome $index',
          userId: _userId,
        );
      }
      await a.host.deliverAll();
      final segment = File('${directory.path}/ops/${a.memberId}/000001.log');
      final whole = segment.readAsBytesSync();
      final records = readRecords(whole);
      expect(records.length, greaterThanOrEqualTo(3));
      final lastStart = records[records.length - 2].endOffset;
      segment.writeAsBytesSync(Uint8List.sublistView(whole, 0, lastStart + 10));

      await b.plugin!.scan();
      await b.host.deliverAll();
      expect((await _todoRows(b.device)).length, lessThan(3));
      expect(await _alarms(b), isEmpty, reason: 'a partial record is not yet arrived');
      final peer = await (b.device.sync.select(b.device.sync.folderPeers)).getSingle();
      expect(peer.cursorOffsetBytes, lastStart);

      segment.writeAsBytesSync(whole);
      await b.plugin!.scan();
      expect(await _todoRows(b.device), await _todoRows(a.device));
      expect(await _alarms(b), isEmpty);
    });
  });

  group('criterion 4: a rolled-back segment raises an integrity alarm', () {
    test('and the alarm resolves when the file is whole again', () async {
      final (:directory, :a, :b) = await _pair();
      for (var index = 0; index < 2; index++) {
        a.device.wall.advance();
        await a.device.domain.todoDao.insertOutcome(
          id: const [_outcomeA, _outcomeB][index],
          title: 'Outcome $index',
          userId: _userId,
        );
      }
      await propagate(a, b);
      final segment = File('${directory.path}/ops/${a.memberId}/000001.log');
      final whole = segment.readAsBytesSync();
      final records = readRecords(whole);
      final stateBefore = await canonicalReducedState(b.device.sync);

      segment.writeAsBytesSync(Uint8List.sublistView(whole, 0, records.first.endOffset));
      await b.plugin!.scan();
      var alarms = await _alarms(b);
      expect(alarms.where((row) => row.resolvedAt == null).map((row) => row.kind),
          ['segment_rolled_back']);
      expect(await canonicalReducedState(b.device.sync), stateBefore,
          reason: 'a rolled-back file loses nothing already merged');

      segment.writeAsBytesSync(whole);
      await b.plugin!.scan();
      alarms = await _alarms(b);
      expect(alarms.single.resolvedAt, isNotNull);
    });
  });

  group('criterion 5: delivering the same changes twice writes one copy', () {
    test('a redelivered batch and a restarted plugin add no records', () async {
      final (:directory, :a, :b) = await _pair();
      await a.device.domain.todoDao
          .insertOutcome(id: _outcomeA, title: 'From A', userId: _userId);
      await a.host.deliverAll();
      final before = envelopesOf(directory, a.memberId);

      final stored = await a.device.sync
          .customSelect('SELECT last_enqueued_sequence AS s FROM folder_sync_bindings')
          .getSingle();
      final sequence = stored.read<int>('s');
      final replay = [
        SequencedChange(
          sequence,
          Change(
            collection: 'todos',
            entityId: _outcomeA,
            fields: {
              'title': ClockedValue(
                  'From A', a.host.mintClock()),
            },
          ),
        ),
      ];
      expect(await a.plugin!.deliver(replay), sequence);
      expect(await a.plugin!.deliver(replay), sequence);
      await a.host.detach('op-log-folder');
      await a.attach();
      await a.host.deliverAll();

      final after = envelopesOf(directory, a.memberId);
      expect(after.length, before.length);
      final opIds = {for (final envelope in after) headerOf(envelope).opId};
      expect(opIds.length, after.length);
    });

    test('the author chain is unbroken across segments', () async {
      final directory = Directory.systemTemp.createTempSync('folder-sync-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final a = await FolderDevice.open('a', directory);
      final b = await FolderDevice.open('b', directory);
      addTearDown(a.close);
      addTearDown(b.close);
      await a.bind();
      await b.bind();
      await a.pairWith(b);
      await b.pairWith(a);
      await a.attach(rollBytes: 1);
      await b.attach();

      for (var index = 0; index < 3; index++) {
        a.device.wall.advance();
        await a.device.domain.todoDao.insertOutcome(
          id: const [_outcomeA, _outcomeB, _outcomeC][index],
          title: 'Outcome $index',
          userId: _userId,
        );
        await a.host.deliverAll();
      }
      final segments = Directory('${directory.path}/ops/${a.memberId}')
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.log'))
          .toList();
      expect(segments.length, greaterThan(1), reason: 'one record per segment at 1 byte');

      await b.plugin!.scan();
      await b.host.deliverAll();
      expect(await _todoRows(b.device), await _todoRows(a.device));
      expect(await _alarms(b), isEmpty);
    });
  });

  test('every record is bounded by a checksum the reader enforces', () {
    final record = encodeRecord(Uint8List(minimumEnvelopeBytes));
    final flipped = Uint8List.fromList(record)..[10] ^= 0xff;
    expect(readRecords(record), hasLength(1));
    expect(readRecords(flipped), isEmpty);
  });
}
