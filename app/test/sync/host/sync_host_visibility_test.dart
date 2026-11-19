/// The host reports an entity's **effective** visibility.
///
/// A tombstone is history: the host's own rule — the merge core's, and the
/// SQL in `merge_state.dart` — is that a field whose clock is newer than the
/// tombstone is live and revives the entity. An entity that was deleted and
/// then written again is live again, and the host says so: a plugin that
/// renders merged state must not hide it.
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
  test('an entity with a tombstone and no newer field is deleted', () async {
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
    expect(deleted.tombstone, tombstone,
        reason: 'nothing was written after the deletion');
    expect(deleted.fields.keys.toList(), ['title'],
        reason: 'the fields the host holds are still there');
  });

  test('an entity a newer field revived is live again', () async {
    final device = HostDevice.open('a');
    addTearDown(device.close);
    final host = await device.startHost();
    final fieldClock = await host.mintClock();
    final tombstone = await host.mintClock();
    final revival = await host.mintClock();

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
    await host.applyRemote('peer', [
      Change(
        collection: _probeCollection,
        entityId: 'probe-1',
        fields: {'notes': ClockedValue('and notes', revival)},
      ),
    ]);

    final revived = await host.mergedEntity(_probeCollection, 'probe-1');
    expect(revived.tombstone, isNull,
        reason: 'a field newer than the tombstone revives the entity');
    expect(revived.fields.keys.toSet(), {'title', 'notes'},
        reason: 'every field the host holds is still reported');
  });

  test('the snapshot and the merged entity agree on visibility', () async {
    final device = HostDevice.open('a');
    addTearDown(device.close);
    final host = await device.startHost();
    final fieldClock = await host.mintClock();
    final tombstone = await host.mintClock();
    final revival = await host.mintClock();

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
    await host.applyRemote('peer', [
      Change(
        collection: _probeCollection,
        entityId: 'probe-1',
        fields: {'notes': ClockedValue('and notes', revival)},
      ),
    ]);

    final snapshot = await host.snapshot()
        .firstWhere((change) => change.entityId == 'probe-1');
    expect(snapshot.tombstone, isNull,
        reason: 'the snapshot holds the same effective visibility');
    expect(snapshot.fields.keys.toSet(), {'title', 'notes'});
  });
}
