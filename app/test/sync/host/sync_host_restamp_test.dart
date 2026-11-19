/// The sync host can hand a clock back to the device.
///
/// A write made before the session restore answered is stamped with the member
/// id of a session that never comes back. No op carries that clock, so the
/// op-log bridge hands it back to the host, and the host re-stamps it under the
/// device node id — the identity the rebuild from the op log, the signed-out
/// upload and the enrolment upload all look for.
///
/// The re-stamp matches the **exact** clock: a field written again since keeps
/// its newer clock, and a clock already under the device node id is left alone.
@TestOn('!browser')
library;

import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/collection_codecs.dart' show todosCollection;
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/host/change.dart';
import 'package:jeeves/sync/host/sync_host_service.dart';

import 'host_harness.dart';

const String _userId = 'restamp-user';
const String _outcomeA = '5a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d';
const String _outcomeB = '6b2c3d4e-5f60-4b7c-8d9e-0f1a2b3c4d5e';
const String _outcomeC = '7c3d4e5f-6071-4c8d-9e0f-1a2b3c4d5e6f';

/// A member id no op on this device ever carries — the one a session that is
/// never restored leaves behind.
const String _memberIdHex = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';

/// The clock merge state holds for one field.
Future<Hlc?> fieldClockOf(
  HostDevice device,
  String collection,
  String entityId,
  String field,
) async {
  final row = await device.sync
      .customSelect(
        'SELECT wall_ms, counter, member_id_hex FROM field_clocks '
        'WHERE collection = ? AND entity_id = ? AND field = ?',
        variables: [
          Variable<String>(collection),
          Variable<String>(entityId),
          Variable<String>(field),
        ],
      )
      .getSingleOrNull();
  if (row == null) return null;
  return Hlc(
    row.read<int>('wall_ms'),
    row.read<int>('counter'),
    row.read<String>('member_id_hex'),
  );
}

/// The clock merge state holds for one entity's deletion.
Future<Hlc?> tombstoneClockOf(
  HostDevice device,
  String collection,
  String entityId,
) async {
  final row = await device.sync
      .customSelect(
        'SELECT wall_ms, counter, member_id_hex FROM row_tombstones '
        'WHERE collection = ? AND entity_id = ?',
        variables: [Variable<String>(collection), Variable<String>(entityId)],
      )
      .getSingleOrNull();
  if (row == null) return null;
  return Hlc(
    row.read<int>('wall_ms'),
    row.read<int>('counter'),
    row.read<String>('member_id_hex'),
  );
}

/// A device whose writes are stamped with [memberIdHex], as a device killed
/// while signed in stamps them: the member id is still on the row.
Future<HostDevice> openDeviceEnrolledAs(String memberIdHex) async {
  final device = HostDevice.open('restamp');
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
  test('a member-stamped field clock and a member-stamped tombstone take the '
      'device node id', () async {
    final device = await openDeviceEnrolledAs(_memberIdHex);
    final host = device.host!;
    final merged = collectMerged(host);

    await device.domain.todoDao
        .insertOutcome(id: _outcomeA, title: 'First', userId: _userId);
    await device.domain.todoDao
        .insertOutcome(id: _outcomeB, title: 'Second', userId: _userId);
    await device.domain.todoDao.deleteOutcome(_outcomeB);

    final fieldClock =
        merged.firstWhere((c) => c.entityId == _outcomeA).fields['title']!.hlc;
    final tombstoneClock = merged
        .firstWhere((c) => c.entityId == _outcomeB && c.tombstone != null)
        .tombstone!;
    expect(fieldClock.memberIdHex, _memberIdHex);
    expect(tombstoneClock.memberIdHex, _memberIdHex);

    await host.restampUnauthoredClocksAsDevice([
      (collection: todosCollection, entityId: _outcomeA, clock: fieldClock),
      (
        collection: todosCollection,
        entityId: _outcomeB,
        clock: tombstoneClock
      ),
    ]);

    expect(
        (await fieldClockOf(device, todosCollection, _outcomeA, 'title'))!
            .memberIdHex,
        host.deviceNodeId);
    expect(
        (await tombstoneClockOf(device, todosCollection, _outcomeB))!.memberIdHex,
        host.deviceNodeId);
  });

  test('a field written again since keeps its newer clock when only the older '
      'clock is handed back', () async {
    final device = await openDeviceEnrolledAs(_memberIdHex);
    final host = device.host!;
    final merged = collectMerged(host);

    await device.domain.todoDao
        .insertOutcome(id: _outcomeA, title: 'First', userId: _userId);
    final older = merged.first.fields['title']!.hlc;

    device.wall.advance();
    await device.domain.todoDao.updateFields(_outcomeA, title: 'Second');
    final newer = merged.last.fields['title']!.hlc;
    expect(newer > older, isTrue,
        reason: 'the second write carries a newer clock');

    await host.restampUnauthoredClocksAsDevice([
      (collection: todosCollection, entityId: _outcomeA, clock: older),
    ]);

    expect(await fieldClockOf(device, todosCollection, _outcomeA, 'title'),
        newer,
        reason: 'the field keeps the clock of the write that is still the '
            'latest one');
  });

  test('a clock already under the device node id, and another entity\'s '
      'member-stamped clock, are unchanged', () async {
    final device = await openDeviceEnrolledAs(_memberIdHex);
    final host = device.host!;
    final merged = collectMerged(host);

    await device.domain.todoDao
        .insertOutcome(id: _outcomeA, title: 'First', userId: _userId);
    await device.domain.todoDao
        .insertOutcome(id: _outcomeB, title: 'Second', userId: _userId);
    // The member id is gone: a write from here on is the device's own.
    await device.domain.customStatement(
        'UPDATE device_clock_identity SET enrolled_member_id_hex = NULL '
        'WHERE id = 1');
    await device.domain.todoDao
        .insertOutcome(id: _outcomeC, title: 'Third', userId: _userId);

    final a =
        merged.firstWhere((c) => c.entityId == _outcomeA).fields['title']!.hlc;
    final b =
        merged.firstWhere((c) => c.entityId == _outcomeB).fields['title']!.hlc;
    final c =
        merged.firstWhere((c) => c.entityId == _outcomeC).fields['title']!.hlc;
    expect(c.memberIdHex, host.deviceNodeId,
        reason: 'a write with no member id on the row is the device\'s own');

    await host.restampUnauthoredClocksAsDevice([
      (collection: todosCollection, entityId: _outcomeC, clock: c),
      (collection: todosCollection, entityId: _outcomeA, clock: a),
    ]);

    expect(await fieldClockOf(device, todosCollection, _outcomeC, 'title'), c,
        reason: 'a clock already under the device node id is left alone');
    expect(
        await fieldClockOf(device, todosCollection, _outcomeA, 'title'),
        Hlc(a.wallMs, a.counter, host.deviceNodeId));
    expect(
        await fieldClockOf(device, todosCollection, _outcomeB, 'title'),
        Hlc(b.wallMs, b.counter, _memberIdHex),
        reason: 'another entity is not touched');
  });

  test('after the re-stamp, changesStampedByDevice returns the change',
      () async {
    final device = await openDeviceEnrolledAs(_memberIdHex);
    final host = device.host!;
    final merged = collectMerged(host);

    await device.domain.todoDao
        .insertOutcome(id: _outcomeA, title: 'First', userId: _userId);
    final clock = merged.first.fields['title']!.hlc;

    expect(await host.changesStampedByDevice(), isEmpty,
        reason: 'nothing the device made is under the device node id yet');

    await host.restampUnauthoredClocksAsDevice([
      (collection: todosCollection, entityId: _outcomeA, clock: clock),
    ]);

    final changes = await host.changesStampedByDevice();
    expect(changes.length, 1);
    expect(changes.single.collection, todosCollection);
    expect(changes.single.entityId, _outcomeA);
    expect(changes.single.fields['title']!.hlc.memberIdHex, host.deviceNodeId);
  });
}
