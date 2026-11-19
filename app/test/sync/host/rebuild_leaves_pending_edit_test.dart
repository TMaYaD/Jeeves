/// A re-projection of the whole store leaves an edit that is still in the
/// outbox where the user put it.
///
/// The walk writes what merge state holds, and an edit that has not been merged
/// yet is not in merge state: the domain row is ahead of it. On the first launch
/// after an update the walk starts before the sync host is attached, so that is
/// the state of every edit made in those first moments.
@TestOn('!browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/domain_rebuild.dart';

import 'host_harness.dart';

void main() {
  test(
      'the walk does not write merge state over an edit still in the outbox, '
      'and the drain keeps the edit', () async {
    final device = HostDevice.open('pending-edit');
    addTearDown(device.close);
    final host = await device.startHost();
    const outcome = '7c1e2d3f-4a5b-4c6d-8e9f-0a1b2c3d4e5f';
    await device.domain.todoDao
        .insertOutcome(id: outcome, title: 'Before', userId: 'walk-user');

    // The host is not attached, as on a launch whose walk starts first: the
    // edit commits with its change in the outbox and waits there.
    device.capture.detach();
    device.wall.advance();
    await device.domain.todoDao.updateFields(outcome, title: 'Edited');
    expect(
      await device.domain.customSelect('SELECT * FROM pending_changes').get(),
      isNotEmpty,
    );

    final projected = await rebuildDomainFromOpLog(
      sync: device.sync,
      domain: device.domain,
    );
    expect(projected, greaterThan(0));
    expect((await device.domain.todoDao.getTodo(outcome))!.title, 'Edited',
        reason: 'merge state still holds the title from before the edit');

    device.capture.attach(host);
    await host.drain();
    expect(
      await device.domain.customSelect('SELECT * FROM pending_changes').get(),
      isEmpty,
    );
    expect((await device.domain.todoDao.getTodo(outcome))!.title, 'Edited');
  });
}
