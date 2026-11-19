/// A peer's change to an entity that has a local change in the outbox is
/// projected, and reconciled, when it arrives.
///
/// Each Project link is its own sync entity, so last-write-wins never compares
/// two of them: the one-Project rule is a convergence pass, and it runs on what
/// a remote projection changed. The outbox drain projects too, and runs no pass.
/// So a remote assignment left for the drain to project would leave the Outcome
/// holding two Projects with nothing outstanding to repair it.
@TestOn('!browser')
library;

import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/daos/tag_dao.dart' show todoTagIdFor;
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/host/change.dart';

import 'host_harness.dart';

void main() {
  test(
      'an Outcome a peer assigns to a Project while a local reassignment is '
      'in the outbox holds one Project once the outbox drains', () async {
    final device = HostDevice.open('pending-project');
    addTearDown(device.close);
    final host = await device.startHost();
    const outcome = '3f2d1c4e-5a6b-4c8d-9e0f-1a2b3c4d5e6f';
    const user = 'review-user';
    await device.domain.todoDao.insertOutcome(id: outcome, title: 'Outcome', userId: user);
    final a = await device.domain.tagDao.findOrCreateTag('Project A', 'project', user);
    final b = await device.domain.tagDao.findOrCreateTag('Project B', 'project', user);
    await device.domain.tagDao.enforceSingleProject(outcome, user, b);
    device.wall.advance();
    await device.domain.tagDao.enforceSingleProject(outcome, user, a);

    // Hold the ordinary durable outbox, as when startup has not attached its
    // drainer yet, or another drain is queued behind work already in flight.
    device.capture.detach();
    device.wall.advance();
    await device.domain.tagDao.enforceSingleProject(outcome, user, b);
    expect(await device.domain.tagDao.outcomesWithMultipleProjects(), isEmpty);
    expect(await device.domain.customSelect('SELECT * FROM pending_changes').get(), isNotEmpty);

    // A peer reassigns A after our switch to B. Its link wins over our pending
    // tombstone, so the Outcome now has a link to A in merge state and a link
    // to B in the domain store.
    final remoteClock = Hlc(device.wall.nowMs + 10000, 0, 'f' * 32);
    await host.applyRemote('peer', [Change(
      collection: 'todo_tags',
      entityId: todoTagIdFor(outcome, a),
      fields: {
        'todo_id': ClockedValue(outcome, remoteClock),
        'tag_id': ClockedValue(a, remoteClock),
        'user_id': ClockedValue(user, remoteClock),
      },
    )]);

    device.capture.attach(host);
    await host.drain();
    expect(await device.domain.customSelect('SELECT * FROM pending_changes').get(), isEmpty);
    expect(await device.domain.tagDao.outcomesWithMultipleProjects(), isEmpty,
        reason: 'the one-Project pass must have run on the remote assignment');
    final links = await device.domain.customSelect(
      'SELECT tag_id FROM todo_tags WHERE todo_id = ?',
      variables: [Variable<String>(outcome)],
    ).get();
    expect([for (final link in links) link.read<String>('tag_id')], [a],
        reason: 'the later assignment, the peer\'s, is the one that stands');
  });
}
