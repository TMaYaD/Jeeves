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
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/host/change.dart';
import 'package:jeeves/sync/signed_out_upload.dart';
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

  test('a setting carried into the account reaches another device', () async {
    final phone = await signedOutPhone();
    // The row the carry leaves behind: stored under the account, written while
    // the account was signed out, so clocked under the device.
    await phone.domain.userPreferencesDao.set(_userId, 'theme', '"dark"');
    final preferences = await phone.preferencesClient;

    expect(await phone.activate(), SyncActivation.active);
    await flush(phone);
    await preferences.flushOutbox();

    final witness = await phoneNamed('B');
    await witness.enrolWithPassphrase(_passphrase);
    expect(await witness.activate(), SyncActivation.active);

    expect(await witness.domain.userPreferencesDao.get(_userId, 'theme'),
        '"dark"');
  });

  test('a snooze set while signed out reaches the account and a second device',
      () async {
    const key = 'planning_notification_snoozed_until';
    final phone = await signedOutPhone();
    await phone.domain.userPreferencesDao.set('local', key,
        '"2026-01-01T18:00:00.000Z"', updatedAt: '2026-01-01T09:00:00.000Z');
    await phone.domain.userPreferencesDao.carryNewestPreferencesInto(_userId);
    final preferences = await phone.preferencesClient;

    expect(await phone.activate(), SyncActivation.active);
    await flush(phone);
    await preferences.flushOutbox();

    final witness = await phoneNamed('B');
    await witness.enrolWithPassphrase(_passphrase);
    expect(await witness.activate(), SyncActivation.active);
    expect(await witness.domain.userPreferencesDao.get(_userId, key),
        '"2026-01-01T18:00:00.000Z"');
  });

  test('a carry over a cleared snooze leaves the account snooze alone and '
      'authors nothing', () async {
    const key = 'planning_notification_snoozed_until';
    final phone = await phoneNamed('A');
    await phone.enrolAsFirstDevice(passphrase: _passphrase);
    expect(await phone.activate(), SyncActivation.active);
    clock.advance(1000);
    await phone.domain.userPreferencesDao.set(_userId, key,
        '"2026-01-01T18:00:00.000Z"', updatedAt: '2026-01-01T09:00:00.000Z');
    final preferences = await phone.preferencesClient;
    await preferences.flushOutbox();
    await phone.lifecycle!.deactivate();
    phone.lifecycle = null;
    clock.advance(1000);
    await phone.domain.userPreferencesDao.set('local', key, null,
        updatedAt: '2026-01-01T10:00:00.000Z');
    final storedBefore = server.storedOps.length;

    await phone.domain.userPreferencesDao.carryNewestPreferencesInto(_userId);
    expect(await phone.domain.userPreferencesDao.get(_userId, key),
        '"2026-01-01T18:00:00.000Z"');
    expect(await phone.activate(), SyncActivation.active);
    await flush(phone);
    await preferences.flushOutbox();

    expect(await phone.domain.userPreferencesDao.get(_userId, key),
        '"2026-01-01T18:00:00.000Z"');
    expect(server.storedOps.length, storedBefore);
  });

  test('a second activation authors nothing further', () async {
    final phone = await signedOutPhone();
    await phone.domain.userPreferencesDao.set(_userId, 'theme', '"dark"');
    final preferences = await phone.preferencesClient;

    expect(await phone.activate(), SyncActivation.active);
    await flush(phone);
    await preferences.flushOutbox();
    final opsAfterFirst = server.storedOps.length;

    await phone.lifecycle!.deactivate();
    phone.lifecycle = null;
    expect(await phone.activate(), SyncActivation.active);
    await flush(phone);
    await preferences.flushOutbox();

    expect(server.storedOps.length, opsAfterFirst);
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

  test('a newer edit from another device wins and is not re-authored',
      () async {
    final phone = await signedOutPhone();
    clock.advance(1000);
    await phone.domain.todoDao.updateFields(_editedId, title: 'Edited signed out');
    final witness = await phoneNamed('B');
    await witness.enrolWithPassphrase(_passphrase);
    expect(await witness.activate(), SyncActivation.active);
    clock.advance(1000);
    await witness.domain.todoDao.updateFields(_editedId, title: 'Edited remotely');
    await flush(witness);
    final opsBeforeSignIn = server.storedOps.length;

    expect(await phone.activate(), SyncActivation.active);
    await flush(phone);

    expect(server.storedOps.length, opsBeforeSignIn,
        reason: 'the pull replaced the device-stamped field, so nothing is left '
            'to author');
    for (final device in [phone, witness]) {
      final todos = await todosOf(device);
      expect(
          todos.firstWhere((row) => row['id'] == _editedId)['title'],
          'Edited remotely');
    }
  });

  test('a tag removed and put back while signed out ends assigned', () async {
    final phone = await phoneNamed('A');
    await phone.enrolAsFirstDevice(passphrase: _passphrase);
    expect(await phone.activate(), SyncActivation.active);
    await insert(phone, _editedId, _userId);
    final tagId =
        await phone.domain.tagDao.findOrCreateTag('errands', 'context', _userId);
    await phone.domain.tagDao.assignTag(_editedId, tagId, _userId);
    await flush(phone);
    await phone.lifecycle!.deactivate();
    phone.lifecycle = null;

    clock.advance(1000);
    await phone.domain.capturing(
        () => phone.domain.tagDao.unassignTag(_editedId, tagId));
    clock.advance(1000);
    await phone.domain.tagDao.assignTag(_editedId, tagId, 'local');

    expect(await phone.activate(), SyncActivation.active);
    await flush(phone);
    final witness = await phoneNamed('B');
    await witness.enrolWithPassphrase(_passphrase);
    expect(await witness.activate(), SyncActivation.active);

    final links = await witness.domain
        .customSelect('SELECT todo_id, tag_id FROM todo_tags')
        .get();
    expect([for (final row in links) row.data],
        [
      {'todo_id': _editedId, 'tag_id': tagId}
    ]);
  });

  test('a write made while the pass reads stays newer than what was read',
      () async {
    final phone = await phoneNamed('A');
    await phone.enrolAsFirstDevice(passphrase: _passphrase);
    expect(await phone.activate(), SyncActivation.active);
    await insert(phone, _editedId, _userId);
    await flush(phone);
    final gtdClient = phone.stack.defaultClient;

    await runSignedOutUpload(
      readChanges: () async {
        // The read has already sampled the old value; the user writes now.
        clock.advance(1000);
        await phone.domain.todoDao.updateFields(_editedId, title: 'Typed meanwhile');
        return [
          Change(
            collection: 'todos',
            entityId: _editedId,
            fields: {
              'title': ClockedValue(
                  'Read before the write', Hlc(0, 0, phone.host!.deviceNodeId)),
            },
          ),
        ];
      },
      mintClock: phone.host!.clockForMember(phone.stack.identity.memberIdHex).send,
      gtdClient: gtdClient,
      preferencesClient: await phone.preferencesClient,
      userId: _userId,
    );
    await flush(phone);

    final witness = await phoneNamed('B');
    await witness.enrolWithPassphrase(_passphrase);
    expect(await witness.activate(), SyncActivation.active);
    expect(
        (await todosOf(witness)).single['title'], 'Typed meanwhile');
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
