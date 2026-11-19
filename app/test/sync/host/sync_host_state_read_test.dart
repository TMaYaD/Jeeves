/// The host reads an entity's merged state from one snapshot of merge state.
///
/// A merge commits a change's fields and its tombstone together, so a read
/// that took the fields in one query and the tombstone in another could see
/// one commit's fields and another's tombstone — a state the store never
/// held. The read is one statement, so it cannot straddle a commit.
@TestOn('!browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/host/change.dart';

import 'host_harness.dart';

/// A collection this build has no codec for: the merge reduces it, and the
/// projector has no typed row to make of it, so the test is about the host's
/// merge alone.
const String _probeCollection = 'host_probe';

void main() {
  test('an entity the store holds nothing about is empty', () async {
    final device = HostDevice.open('a');
    addTearDown(device.close);
    final host = await device.startHost();

    final absent = await host.mergedEntity(_probeCollection, 'nobody');

    expect(absent.fields, isEmpty);
    expect(absent.tombstone, isNull);
  });

  test('an entity whose only trace is its tombstone carries that tombstone',
      () async {
    final device = HostDevice.open('a');
    addTearDown(device.close);
    final host = await device.startHost();
    final tombstone = await host.mintClock();

    await host.applyRemote('peer', [
      Change(
        collection: _probeCollection,
        entityId: 'deleted',
        tombstone: tombstone,
      ),
    ]);

    final deleted = await host.mergedEntity(_probeCollection, 'deleted');
    expect(deleted.fields, isEmpty);
    expect(deleted.tombstone, tombstone,
        reason: 'a tombstone-only entity is not an absent one');
  });

  test('an entity with fields and a tombstone carries both', () async {
    final device = HostDevice.open('a');
    addTearDown(device.close);
    final host = await device.startHost();
    final fieldClock = await host.mintClock();
    final tombstone = await host.mintClock();

    await host.applyRemote('peer', [
      Change(
        collection: _probeCollection,
        entityId: 'probe-1',
        fields: {'title': ClockedValue('Ship it', fieldClock)},
      ),
    ]);
    await host.applyRemote('peer', [
      Change(
        collection: _probeCollection,
        entityId: 'probe-1',
        tombstone: tombstone,
      ),
    ]);

    final deleted = await host.mergedEntity(_probeCollection, 'probe-1');
    expect(deleted.fields.keys.toList(), ['title'],
        reason: 'the fields the host holds are still there');
    expect(deleted.fields['title']?.hlc, fieldClock);
    expect(deleted.tombstone, tombstone);
  });
}
