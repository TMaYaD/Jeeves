/// What a device wrote while it was killed, before it ever authored it.
///
/// A process killed while signed in leaves the member id stored and the op-log
/// bridge undecided. The writes it made in that window were merged into merge
/// state, but the bridge that would have authored them died with the process:
/// the ops never reached the log, so no other device ever sees them, and a
/// rebuild from the log reverts them.
///
/// Driven through two hosted phones over one fake server: the second device is
/// the witness that the ops really left the first.
@TestOn('!browser')
library;

import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/collection_codecs.dart' show todosCollection;
import 'package:jeeves/sync/sync_lifecycle.dart';

import '../../test_helpers.dart';
import '../harness/fake_sync_server.dart';
import '../harness/sim_device.dart' show FakeClock;
import '../harness/sim_workspace.dart' show simulationStartWallMs;
import '../harness/stack_phone.dart';

const String _userId = 'killed-before-authoring-user';
const String _passphrase = 'correct horse battery staple';
const String _editedId = '61111111-1111-4111-8111-111111111111';
const String _deletedId = '62222222-2222-4222-8222-222222222222';
const String _createdId = '63333333-3333-4333-8333-333333333333';
const String _editedTitle = 'Edited before the kill';

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

  Future<List<Map<String, Object?>>> todosOf(StackPhone phone) async => [
        for (final row in await phone.domain
            .customSelect('SELECT id, title, user_id FROM todos ORDER BY id')
            .get())
          row.data,
      ];

  /// The member id the winning clock of `(entityId, field)` names.
  Future<String> clockOf(StackPhone phone, String entityId, String field) async {
    final row = await phone.syncStore
        .customSelect(
          'SELECT member_id_hex FROM field_clocks '
          'WHERE collection = ? AND entity_id = ? AND field = ?',
          variables: [
            Variable<String>(todosCollection),
            Variable<String>(entityId),
            Variable<String>(field),
          ],
        )
        .getSingle();
    return row.read<String>('member_id_hex');
  }

  /// A phone killed in the window between the merge and the authoring.
  ///
  /// The three writes it made in that window were merged into merge state and
  /// buffered by a bridge that never got to author them: the kill dropped the
  /// bridge and its buffer with it.
  Future<StackPhone> killedWithUnauthoredChanges() async {
    final phone = await phoneNamed('A');
    await phone.enrolAsFirstDevice(passphrase: _passphrase);
    expect(await phone.activate(), SyncActivation.active);
    await insert(phone, _editedId, _userId);
    await insert(phone, _deletedId, _userId);
    await flush(phone);

    await phone.relaunchAfterKill();

    // The window: the user writes while the bridge is still undecided.
    await insert(phone, _createdId, 'local');
    clock.advance(1000);
    await phone.domain.todoDao.updateFields(_editedId, title: _editedTitle);
    clock.advance(1000);
    await phone.domain.todoDao.deleteOutcome(_deletedId);

    // The write carries the member id the killed process left behind.
    expect(await clockOf(phone, _editedId, 'title'),
        phone.stack.identity.memberIdHex,
        reason: 'precondition: the write is clocked under the member id');

    // The kill: the bridge holding the three changes is dropped with it.
    await phone.relaunchAfterKill();
    return phone;
  }

  test('the write is authored on the next launch', () async {
    final phone = await killedWithUnauthoredChanges();

    expect(await phone.activate(), SyncActivation.active);
    await flush(phone);

    final witness = await phoneNamed('B');
    await witness.enrolWithPassphrase(_passphrase);
    expect(await witness.activate(), SyncActivation.active);

    final todos = await todosOf(witness);
    expect(todos.map((row) => row['id']), [_editedId, _createdId]);
    expect(
        todos.firstWhere((row) => row['id'] == _editedId)['title'], _editedTitle);
  });

  test('the write survives a rebuild from the op log once authored', () async {
    final phone = await killedWithUnauthoredChanges();

    expect(await phone.activate(), SyncActivation.active);
    await flush(phone);
    await phone.stack.defaultClient.pull();

    final affected = await phone.stack.defaultClient.rebuildFromOpLog();
    await phone.host!.projector.project(affected);

    final todos = await todosOf(phone);
    expect(todos.map((row) => row['id']), [_editedId, _createdId]);
    expect(
        todos.firstWhere((row) => row['id'] == _editedId)['title'], _editedTitle);
  });

  test('the write is handed to the device when the session is lost', () async {
    final phone = await killedWithUnauthoredChanges();

    phone.capture.unbind();
    await phone.capture.unauthoredHandedBack;

    expect(await clockOf(phone, _editedId, 'title'), phone.host!.deviceNodeId,
        reason: 'the clock of a change no op carried names the device');

    final affected = await phone.stack.defaultClient.rebuildFromOpLog();
    await phone.host!.projector.project(affected);

    final todos = await todosOf(phone);
    expect(todos.map((row) => row['id']), [_editedId, _createdId]);
    expect(
        todos.firstWhere((row) => row['id'] == _editedId)['title'], _editedTitle);
  });
}
