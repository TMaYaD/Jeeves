/// The sync store remembers a merged change that still needs an op.
///
/// A write made while the device was signed in carries the member id of that
/// session. The op-log bridge authors it into the log, and until it has, the
/// change lives only in merge state — so a process killed in that window loses
/// it, and the next launch finds no trace of a change that still needs an op.
///
/// The sync store therefore records the change in the transaction that merges
/// it, and the record leaves when the bridge has authored the change or handed
/// it back.
///
/// The bridge is handed the record, not the merge: a change that still needs an
/// op is exactly a change in that table. The host hands it over at the start of
/// the process — for whatever a killed process left behind — and after every
/// drain.
@TestOn('!browser')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/collection_codecs.dart' show todosCollection;
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/host/change.dart';
import 'package:jeeves/sync/host/sync_host_service.dart';

import 'host_harness.dart';

const String _userId = 'unauthored-user';
const String _outcomeA = '8a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d';
const String _outcomeB = '9b2c3d4e-5f60-4b7c-8d9e-0f1a2b3c4d5e';
const String _outcomeC = 'ac3d4e5f-6f71-4c8d-9e0f-1a2b3c4d5e6f';

/// A member id no op on this device ever carries — the one a session that is
/// never restored leaves behind.
const String _memberIdHex = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';

/// One row of `unauthored_changes`, as the store holds it.
class UnauthoredRecord {
  const UnauthoredRecord({
    required this.id,
    required this.changeId,
    required this.collection,
    required this.entityId,
    required this.memberIdHex,
    required this.wallMs,
    required this.counter,
    required this.changeJson,
  });

  final int id;
  final String changeId;
  final String collection;
  final String entityId;
  final String memberIdHex;
  final int wallMs;
  final int counter;
  final String changeJson;

  /// The change the row holds.
  Change get change => Change.fromJson(
      (jsonDecode(changeJson) as Map).cast<String, Object?>());
}

/// Every recorded change, oldest first.
Future<List<UnauthoredRecord>> recordsOf(HostDevice device) async {
  final rows = await device.sync
      .customSelect(
        'SELECT id, change_id, collection, entity_id, member_id_hex, wall_ms, '
        'counter, change_json FROM unauthored_changes ORDER BY id',
      )
      .get();
  return [
    for (final row in rows)
      UnauthoredRecord(
        id: row.read<int>('id'),
        changeId: row.read<String>('change_id'),
        collection: row.read<String>('collection'),
        entityId: row.read<String>('entity_id'),
        memberIdHex: row.read<String>('member_id_hex'),
        wallMs: row.read<int>('wall_ms'),
        counter: row.read<int>('counter'),
        changeJson: row.read<String>('change_json'),
      ),
  ];
}

/// A device whose writes carry [memberIdHex], as a device killed while signed
/// in stamps them: the member id is still on the row.
Future<HostDevice> openDeviceSignedInAs(String memberIdHex) async {
  final device = HostDevice.open('unauthored');
  addTearDown(device.close);
  await device.domain.ensureDeviceClockIdentity();
  await device.domain.customStatement(
    'UPDATE device_clock_identity SET enrolled_member_id_hex = ?',
    [memberIdHex],
  );
  await device.startHost();
  return device;
}

/// The changes the host merged, as the op-log bridge sees them.
List<Change> collectMerged(SyncHostService host) {
  final merged = <Change>[];
  host.localChangeListener = (changes) async {
    merged.addAll(changes);
  };
  return merged;
}

void main() {
  test('a member-stamped local write leaves one record holding its clock and '
      'its change', () async {
    final device = await openDeviceSignedInAs(_memberIdHex);
    final merged = collectMerged(device.host!);

    await device.domain.todoDao
        .insertOutcome(id: _outcomeA, title: 'First', userId: _userId);

    final records = await recordsOf(device);
    expect(records.length, 1, reason: 'the change still needs an op');
    final record = records.single;
    final clock = merged.single.fields['title']!.hlc;
    expect(record.collection, todosCollection);
    expect(record.entityId, _outcomeA);
    expect(record.memberIdHex, _memberIdHex,
        reason: 'the clock names the session, not the device');
    expect(record.wallMs, clock.wallMs);
    expect(record.counter, clock.counter);
    expect(record.change.fields['title']!.hlc, clock,
        reason: 'the record holds the clock the change was merged at');
    expect(record.change.fields['title']!.value, 'First');
  });

  test('a device-stamped local write leaves no record', () async {
    final device = HostDevice.open('unauthored');
    addTearDown(device.close);
    await device.startHost();

    await device.domain.todoDao
        .insertOutcome(id: _outcomeA, title: 'First', userId: _userId);

    expect(await recordsOf(device), isEmpty,
        reason: 'no op will ever carry a change this device made, so it never '
            'needed one');
  });

  test('a change from applyRemote leaves no record', () async {
    final device = await openDeviceSignedInAs(_memberIdHex);
    final host = device.host!;

    await host.applyRemote('relay', [
      Change(
        collection: todosCollection,
        entityId: _outcomeA,
        fields: {
          'title': ClockedValue(
              'From the relay', Hlc(1700000000000, 0, 'b' * 32)),
        },
      ),
    ]);

    expect(await recordsOf(device), isEmpty,
        reason: 'a change that arrived from elsewhere was never this '
            'device\'s to author');
  });

  test('an outbox row replayed after its merge committed leaves one record',
      () async {
    final device = HostDevice.open('unauthored');
    addTearDown(device.close);
    await device.domain.ensureDeviceClockIdentity();
    await device.domain.customStatement(
      'UPDATE device_clock_identity SET enrolled_member_id_hex = ?',
      [_memberIdHex],
    );
    // No host attached yet: the write waits in the outbox.
    await device.domain.todoDao
        .insertOutcome(id: _outcomeA, title: 'First', userId: _userId);
    await device.domain.customStatement(
      'CREATE TRIGGER fail_delete BEFORE DELETE ON pending_changes '
      'BEGIN SELECT RAISE(ABORT, \'boom\'); END',
    );

    final host = SyncHostService(
        sync: device.sync, domain: device.domain, clock: device.clock);
    await expectLater(host.start(), throwsA(anything));

    expect((await recordsOf(device)).length, 1,
        reason: 'the merge committed; only the outbox delete failed');

    await device.domain.customStatement('DROP TRIGGER fail_delete');
    await host.drain();

    expect((await recordsOf(device)).length, 1,
        reason: 'the replay is the same change, so it is still one record');
    expect(
        await device.domain.customSelect('SELECT 1 FROM pending_changes').get(),
        isEmpty);
  });

  test('forgetUnauthored removes that record and no other', () async {
    final device = await openDeviceSignedInAs(_memberIdHex);
    final merged = collectMerged(device.host!);

    await device.domain.todoDao
        .insertOutcome(id: _outcomeA, title: 'First', userId: _userId);
    device.wall.advance();
    await device.domain.todoDao
        .insertOutcome(id: _outcomeB, title: 'Second', userId: _userId);

    expect((await recordsOf(device)).length, 2);
    final a = merged.firstWhere((c) => c.entityId == _outcomeA).fields['title']!.hlc;
    final b = merged.firstWhere((c) => c.entityId == _outcomeB).fields['title']!.hlc;

    await device.host!
        .forgetUnauthored((collection: todosCollection, entityId: _outcomeA, clock: a));

    final left = await recordsOf(device);
    expect(left.length, 1, reason: 'the other change still needs its op');
    expect(left.single.entityId, _outcomeB);
    expect(left.single.memberIdHex, _memberIdHex);
    expect(left.single.wallMs, b.wallMs);
    expect(left.single.counter, b.counter);
  });

  test('restampUnauthoredClocksAsDevice removes the record of each clock it is '
      'given', () async {
    final device = await openDeviceSignedInAs(_memberIdHex);
    final merged = collectMerged(device.host!);

    await device.domain.todoDao
        .insertOutcome(id: _outcomeA, title: 'First', userId: _userId);
    device.wall.advance();
    await device.domain.todoDao
        .insertOutcome(id: _outcomeB, title: 'Second', userId: _userId);

    expect((await recordsOf(device)).length, 2);
    final a = merged.firstWhere((c) => c.entityId == _outcomeA).fields['title']!.hlc;
    final b = merged.firstWhere((c) => c.entityId == _outcomeB).fields['title']!.hlc;

    await device.host!.restampUnauthoredClocksAsDevice([
      (collection: todosCollection, entityId: _outcomeA, clock: a),
      (collection: todosCollection, entityId: _outcomeB, clock: b),
    ]);

    expect(await recordsOf(device), isEmpty,
        reason: 'the change is the device\'s own now, so it needs no op');
  });

  group('the bridge is handed the record', () {
    test('a record left by a previous host is handed at start, before a change '
        'still in the outbox', () async {
      final device = HostDevice.open('unauthored');
      addTearDown(device.close);
      await device.domain.ensureDeviceClockIdentity();
      await device.domain.customStatement(
        'UPDATE device_clock_identity SET enrolled_member_id_hex = ?',
        [_memberIdHex],
      );
      // The previous host: it merges the write, so the change is recorded, and
      // it has no bridge to hand it to.
      await device.startHost();
      await device.domain.todoDao
          .insertOutcome(id: _outcomeA, title: 'First', userId: _userId);
      expect((await recordsOf(device)).length, 1,
          reason: 'the merge recorded the change');

      // The process is killed: the next write never reaches a drain.
      device.capture.detach();
      await device.domain.todoDao
          .insertOutcome(id: _outcomeB, title: 'Second', userId: _userId);
      expect(
          await device.domain.customSelect('SELECT 1 FROM pending_changes').get(),
          hasLength(1),
          reason: 'the write is still in the outbox');

      // The next launch: a fresh host over the same stores, with a bridge.
      final handed = <Change>[];
      final fresh = SyncHostService(
          sync: device.sync, domain: device.domain, clock: device.clock)
        ..localChangeListener = (changes) async => handed.addAll(changes);
      await fresh.start();

      expect(handed.map((c) => c.entityId), orderedEquals([_outcomeA, _outcomeB]),
          reason: 'the record is handed first, then the change still in the '
              'outbox');
    });

    test('a record is handed once per host: a second drain does not hand it '
        'again', () async {
      final device = await openDeviceSignedInAs(_memberIdHex);
      final handed = <Change>[];
      device.host!.localChangeListener = (changes) async => handed.addAll(changes);

      await device.domain.todoDao
          .insertOutcome(id: _outcomeA, title: 'First', userId: _userId);
      expect(handed.map((c) => c.entityId), orderedEquals([_outcomeA]));

      await device.domain.todoDao
          .insertOutcome(id: _outcomeB, title: 'Second', userId: _userId);
      expect(handed.map((c) => c.entityId), orderedEquals([_outcomeA, _outcomeB]));

      // A third write waits in the outbox, so the next drain has work to do.
      device.capture.detach();
      await device.domain.todoDao
          .insertOutcome(id: _outcomeC, title: 'Third', userId: _userId);
      device.capture.attach(device.host!);
      await device.host!.drain();

      expect(handed.map((c) => c.entityId),
          orderedEquals([_outcomeA, _outcomeB, _outcomeC]),
          reason: 'the records already handed are not handed again');
    });

    test('a listener that throws leaves the record in place', () async {
      final device = await openDeviceSignedInAs(_memberIdHex);
      device.host!.localChangeListener = (changes) async =>
          throw StateError('the bridge is gone');

      await device.domain.todoDao
          .insertOutcome(id: _outcomeA, title: 'First', userId: _userId);

      expect(await recordsOf(device), hasLength(1),
          reason: 'a bridge that failed did not settle the change');
    });
  });
}
