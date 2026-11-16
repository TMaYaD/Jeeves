/// The op-log client riding on the sync host until it becomes a plugin.
///
/// A real [SyncStack] over the harness's platform doubles, with the domain store
/// wired as production wires it: writes stage into the outbox, the host drains
/// them, and the op-log bridge authors from what the host merged.
@TestOn('!browser')
library;

import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/envelope.dart' show opClassContent;
import 'package:jeeves/sync/sync_lifecycle.dart';

import '../../test_helpers.dart';
import '../harness/fake_sync_server.dart';
import '../harness/sim_device.dart' show FakeClock;
import '../harness/sim_workspace.dart' show simulationStartWallMs;
import '../harness/stack_phone.dart';

const String _userId = 'bridge-user';
const String _outcomeBeforeEnrolment = '33333333-3333-4333-8333-333333333333';
const String _outcomeAfterEnrolment = '44444444-4444-4444-8444-444444444444';

int _contentOpCount(FakeSyncServer server) => server.storedOps
    .where((op) => op.header?.opClass == opClassContent)
    .length;

void main() {
  setUpAll(configureSqliteForTests);

  late FakeSyncServer server;
  late FakeClock clock;

  setUp(() {
    server = FakeSyncServer();
    clock = FakeClock(simulationStartWallMs);
  });

  Future<StackPhone> hostedPhone() async {
    final built = await StackPhone.create(
      label: 'A',
      userId: _userId,
      server: server,
      clock: clock,
      hosted: true,
    );
    addTearDown(built.close);
    return built;
  }

  Future<void> writeOutcome(StackPhone phone, String id) async {
    clock.advance(1000);
    await phone.domain.todoDao.insertOutcome(
      id: id,
      title: 'Write the thing',
      userId: _userId,
      now: clock.asDateTime,
    );
  }

  Future<List<Object?>> titleClock(StackPhone phone, String id) async {
    final row = await phone.syncStore.customSelect(
      "SELECT wall_ms, counter, member_id_hex FROM field_clocks "
      "WHERE entity_id = ? AND field = 'title'",
      variables: [Variable<String>(id)],
    ).getSingle();
    return [
      row.read<int>('wall_ms'),
      row.read<int>('counter'),
      row.read<String>('member_id_hex'),
    ];
  }

  test('an activation abandoned during its first read stops before the '
      'enrolment decision', () async {
    final phone = await hostedPhone();

    final activation = phone.activate();
    await phone.lifecycle!.deactivate();

    expect(await activation, SyncActivation.deactivated);
  });

  test('an un-enrolled device keeps merge state and authors no op', () async {
    final phone = await hostedPhone();

    await writeOutcome(phone, _outcomeBeforeEnrolment);
    expect(await phone.activate(), SyncActivation.notEnrolled);

    expect(_contentOpCount(server), 0);
    final clockBefore = await titleClock(phone, _outcomeBeforeEnrolment);
    expect(clockBefore[2], phone.host!.deviceNodeId,
        reason: 'clocked under the device node id, since there is no member');
    final op = await phone.syncStore.customSelect('SELECT COUNT(*) AS c FROM op_log').getSingle();
    expect(op.read<int>('c'), 0);
  });

  test('a write made before enrolling reaches the log when the device enrols',
      () async {
    final phone = await hostedPhone();
    await writeOutcome(phone, _outcomeBeforeEnrolment);
    // The very state the old equal-to-merge-state skip would have mistaken for
    // "already uploaded".
    expect((await titleClock(phone, _outcomeBeforeEnrolment))[2],
        phone.host!.deviceNodeId);

    await phone.enrolAsFirstDevice();
    expect(await phone.activate(), SyncActivation.active);

    expect(_contentOpCount(server), greaterThan(0),
        reason: 'the enrolment upload authored the pre-enrolment write');
    final memberHex = phone.stack.identity.memberIdHex;
    expect((await titleClock(phone, _outcomeBeforeEnrolment))[2], memberHex,
        reason: 'the upload re-asserted it under the member id');
  });

  test('once enrolled, a write is clocked with the member id and authored',
      () async {
    final phone = await hostedPhone();
    await phone.enrolAsFirstDevice();
    expect(await phone.activate(), SyncActivation.active);
    final authoredBefore = _contentOpCount(server);

    await writeOutcome(phone, _outcomeAfterEnrolment);
    await phone.stack.defaultClient.flushOutbox();

    expect((await titleClock(phone, _outcomeAfterEnrolment))[2],
        phone.stack.identity.memberIdHex);
    expect(_contentOpCount(server), greaterThan(authoredBefore));
  });

  test('a rebuild from the log keeps what the log never held', () async {
    final phone = await hostedPhone();
    await writeOutcome(phone, _outcomeBeforeEnrolment);

    final client = phone.stack.defaultClient;
    final affected = await client.rebuildFromOpLog();
    await phone.host!.projector.project(affected);

    expect((await titleClock(phone, _outcomeBeforeEnrolment))[2],
        phone.host!.deviceNodeId,
        reason: 'merge state stamped by the device node id was carried across');
    final todo = await phone.domain
        .customSelect('SELECT title FROM todos WHERE id = ?',
            variables: [Variable<String>(_outcomeBeforeEnrolment)])
        .get();
    expect(todo, hasLength(1),
        reason: 'the projector must not delete a row the user wrote');
    expect(jsonEncode(todo.single.read<String>('title')), '"Write the thing"');
  });
}
