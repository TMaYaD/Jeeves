/// The host reports the changes it refused.
///
/// A plugin that carries content into the app has to know whether the app took
/// it: content the host refused is content the app does not have, and the
/// medium must keep it until the host takes it.
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
  test('a refused change is reported, and the batch around it is merged',
      () async {
    final device = HostDevice.open('a');
    addTearDown(device.close);
    final host = await device.startHost();

    // A preference value with no key names no strategy to merge it by, so the
    // host refuses it (the merge core's one rule about the change itself).
    final refused = Change(
      collection: 'user_preferences',
      entityId: 'pref-1',
      fields: {
        'value': ClockedValue(
          '"2026-03-01T00:00:00.000Z"',
          host.mintClock(),
        ),
      },
    );
    final taken = Change(
      collection: _probeCollection,
      entityId: 'probe-1',
      fields: {
        'title': ClockedValue('Ship it', host.mintClock()),
      },
    );

    final reported = await host.applyRemote('peer', [refused, taken]);

    expect(reported.map((change) => change.entityId).toList(), ['pref-1'],
        reason: 'the refused change is reported to the caller');
    expect((await host.mergedEntity('user_preferences', 'pref-1')).fields,
        isEmpty,
        reason: 'a refused change is not merged');
    expect((await host.mergedEntity(_probeCollection, 'probe-1'))
        .fields['title']?.value,
        'Ship it',
        reason: 'a refused change does not stall the batch around it');
  });

  test('a batch the host took whole reports nothing', () async {
    final device = HostDevice.open('a');
    addTearDown(device.close);
    final host = await device.startHost();

    final reported = await host.applyRemote('peer', [
      Change(
        collection: _probeCollection,
        entityId: 'probe-1',
        fields: {
          'title': ClockedValue('Ship it', host.mintClock()),
        },
      ),
    ]);

    expect(reported, isEmpty);
  });
}
