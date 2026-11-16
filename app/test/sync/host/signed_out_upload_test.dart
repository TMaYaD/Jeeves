/// What a device wrote while nobody was signed in reaches the op log when the
/// account that already uploaded signs back in.
///
/// Driven through two hosted phones over one fake server: the second device is the
/// witness that the ops really left the first.
@TestOn('!browser')
library;

import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/envelope.dart' show opClassContent;
import 'package:jeeves/sync/sync_lifecycle.dart';

import '../../test_helpers.dart';
import '../harness/fake_sync_server.dart';
import '../harness/sim_device.dart' show FakeClock;
import '../harness/sim_workspace.dart' show simulationStartWallMs;
import '../harness/stack_phone.dart';

const String _userId = 'signed-out-user';
const String _passphrase = 'correct horse battery staple';
const String _editedId = '61111111-1111-4111-8111-111111111111';
const String _deletedId = '62222222-2222-4222-8222-222222222222';
const String _createdId = '63333333-3333-4333-8333-333333333333';

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

  Future<StackPhone> phoneNamed(String label) async {
    final phone = await StackPhone.create(
      label: label,
      userId: _userId,
      server: server,
      clock: clock,
      hosted: true,
    );
    addTearDown(phone.close);
    return phone;
  }

  Future<void> insert(StackPhone phone, String id, String userId) async {
    clock.advance(1000);
    await phone.domain.todoDao.insertOutcome(
      id: id,
      title: 'Original title',
      userId: userId,
      now: clock.asDateTime,
    );
  }

  Future<void> flush(StackPhone phone) => phone.stack.defaultClient.flushOutbox();

  /// Enrolled, activated, with the edited and the deleted Outcome on the log and
  /// then signed out the way the provider signs out.
  Future<StackPhone> signedOutPhone() async {
    final phone = await phoneNamed('A');
    await phone.enrolAsFirstDevice(passphrase: _passphrase);
    expect(await phone.activate(), SyncActivation.active);
    await insert(phone, _editedId, _userId);
    await insert(phone, _deletedId, _userId);
    await flush(phone);
    await phone.lifecycle!.deactivate();
    phone.lifecycle = null;
    return phone;
  }

  Future<void> writeSignedOut(StackPhone phone) async {
    await insert(phone, _createdId, 'local');
    clock.advance(1000);
    await phone.domain.todoDao.updateFields(_editedId, title: 'Edited signed out');
    clock.advance(1000);
    await phone.domain.todoDao.deleteOutcome(_deletedId);
  }

  Future<List<Map<String, Object?>>> todosOf(StackPhone phone) async => [
        for (final row in await phone.domain
            .customSelect('SELECT id, title, user_id FROM todos ORDER BY id')
            .get())
          row.data,
      ];

  test('creates, edits and deletes made signed out reach another device',
      () async {
    final phone = await signedOutPhone();
    await writeSignedOut(phone);
    final opsBefore = _contentOpCount(server);

    expect(await phone.activate(), SyncActivation.active);
    await flush(phone);
    expect(_contentOpCount(server), greaterThan(opsBefore));

    final witness = await phoneNamed('B');
    await witness.enrolWithPassphrase(_passphrase);
    expect(await witness.activate(), SyncActivation.active);

    final todos = await todosOf(witness);
    expect(todos.map((row) => row['id']), [_editedId, _createdId]);
    expect(todos.firstWhere((row) => row['id'] == _editedId)['title'],
        'Edited signed out');
    expect(todos.firstWhere((row) => row['id'] == _createdId)['user_id'], _userId,
        reason: 'the account owns a row created signed out');
  });

  test('a second sign-in authors nothing further', () async {
    final phone = await signedOutPhone();
    await writeSignedOut(phone);
    expect(await phone.activate(), SyncActivation.active);
    await flush(phone);
    final opsAfterFirst = server.storedOps.length;

    await phone.lifecycle!.deactivate();
    phone.lifecycle = null;
    expect(await phone.activate(), SyncActivation.active);
    await flush(phone);

    expect(server.storedOps.length, opsAfterFirst);
  });

  test('state from before the account uploaded is not authored again',
      () async {
    final phone = await phoneNamed('A');
    await insert(phone, _editedId, 'local');
    await phone.domain.todoDao.deleteOutcome(_editedId);
    await phone.enrolAsFirstDevice(passphrase: _passphrase);
    expect(await phone.activate(), SyncActivation.active);
    await flush(phone);
    final opsAfterEnrolment = server.storedOps.length;

    await phone.lifecycle!.deactivate();
    phone.lifecycle = null;
    expect(await phone.activate(), SyncActivation.active);
    await flush(phone);

    expect(server.storedOps.length, opsAfterEnrolment);
  });

  test('a preference changed signed out is not authored', () async {
    final phone = await signedOutPhone();
    await phone.domain.userPreferencesDao.set('local', 'theme', '"dark"');
    final preferences = await phone.preferencesClient;
    final storedBefore = server.storedOps.length;

    expect(await phone.activate(), SyncActivation.active);
    await flush(phone);
    await preferences.flushOutbox();

    expect(server.storedOps.length, storedBefore);
  });

  test('an Outcome another device deleted is not revived by a signed-out edit',
      () async {
    final phone = await signedOutPhone();
    clock.advance(1000);
    await phone.domain.todoDao.updateFields(_editedId, title: 'Edited signed out');
    final witness = await phoneNamed('B');
    await witness.enrolWithPassphrase(_passphrase);
    expect(await witness.activate(), SyncActivation.active);
    // The delete is the later write, so it wins wherever the two meet.
    clock.advance(1000);
    await witness.domain.todoDao.deleteOutcome(_editedId);
    await flush(witness);

    expect(await phone.activate(), SyncActivation.active);
    await flush(phone);

    expect((await todosOf(phone)).map((row) => row['id']), [_deletedId]);
    final reloaded = await phoneNamed('C');
    await reloaded.enrolWithPassphrase(_passphrase);
    expect(await reloaded.activate(), SyncActivation.active);
    expect((await todosOf(reloaded)).map((row) => row['id']), [_deletedId]);
  });

  test('device-stamped merge state is re-stamped under the member id',
      () async {
    final phone = await signedOutPhone();
    await writeSignedOut(phone);
    Future<int> deviceStamped() async => (await phone.syncStore.customSelect(
            'SELECT COUNT(*) AS c FROM field_clocks WHERE member_id_hex = ? '
            "AND collection = 'todos'",
            variables: [Variable<String>(phone.host!.deviceNodeId)])
        .getSingle())
        .read<int>('c');
    expect(await deviceStamped(), greaterThan(0));

    expect(await phone.activate(), SyncActivation.active);

    expect(await deviceStamped(), 0);
  });
}
