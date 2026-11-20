/// A write made before the app learns it is signed out is lost on a
/// lost-session launch.
///
/// A process killed while signed in leaves the member id on the clock identity
/// row and no lifecycle behind it. The next launch restores the session, and
/// until that restore answers, the user can write — and the write is stamped
/// with the lost session's member id. If the restore then answers "signed out",
/// the app settles the op-log bridge silent, and the write the bridge was still
/// holding goes with it.
///
/// What is left behind is a clock in the merge state that names a member no op
/// ever carried. A rebuild from the op log reverts the write, and a later
/// sign-in finds nothing device-stamped to upload.
///
/// Driven through two hosted phones over one fake server: the second device is
/// the witness that the ops really left the first.
@TestOn('!browser')
library;

import 'dart:async';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/providers/auth_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/sync_lifecycle_provider.dart';
import 'package:jeeves/sync/collection_codecs.dart' show todosCollection;
import 'package:jeeves/sync/host/hosted_capture.dart' show readClockIdentity;
import 'package:jeeves/sync/sync_lifecycle.dart';

import '../../test_helpers.dart';
import '../harness/fake_sync_server.dart';
import '../harness/sim_device.dart' show FakeClock;
import '../harness/sim_workspace.dart' show simulationStartWallMs;
import '../harness/stack_phone.dart';

const String _userId = 'lost-session-user';
const String _passphrase = 'correct horse battery staple';
const String _editedId = '61111111-1111-4111-8111-111111111111';
const String _deletedId = '62222222-2222-4222-8222-222222222222';
const String _createdId = '63333333-3333-4333-8333-333333333333';
const String _editedTitle = 'Edited before restore answered';

/// Session restore the test answers when it says so.
///
/// The real restore reaches the network; this one leaves the window open, so
/// the app is still waiting when the user writes.
class _ControlledAuth extends AuthNotifier {
  _ControlledAuth(this.restore);

  final Completer<String?> restore;

  @override
  Future<String?> build() => restore.future;
}

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

  /// A device that was killed while signed in, relaunched, and written to
  /// before the app learned whether the session survived.
  ///
  /// Returns the phone, the container watching the real `syncLifecycleProvider`,
  /// and the completer that answers the session restore.
  Future<(StackPhone, ProviderContainer, Completer<String?>)>
      lostSessionLaunch() async {
    final phone = await phoneNamed('A');
    await phone.enrolAsFirstDevice(passphrase: _passphrase);
    expect(await phone.activate(), SyncActivation.active);
    await insert(phone, _editedId, _userId);
    await insert(phone, _deletedId, _userId);
    await flush(phone);

    await phone.relaunchAfterKillWhileSignedIn();

    final restore = Completer<String?>();
    final container = ProviderContainer(overrides: [
      domainOpCaptureProvider.overrideWithValue(phone.capture),
      databaseProvider.overrideWithValue(phone.domain),
      authTokenProvider.overrideWith(() => _ControlledAuth(restore)),
    ]);
    addTearDown(container.dispose);
    // Listen as the app does (main.dart watches it eagerly): an unwatched
    // provider that is invalidated only rebuilds on the next read.
    container.listen(syncLifecycleProvider, (_, _) {});
    expect(await container.read(syncLifecycleProvider.future), isNull,
        reason: 'no lifecycle while the session restore is still in flight');

    // The window: the user writes before the app knows it is signed out.
    await insert(phone, _createdId, 'local');
    clock.advance(1000);
    await phone.domain.todoDao.updateFields(_editedId, title: _editedTitle);
    clock.advance(1000);
    await phone.domain.todoDao.deleteOutcome(_deletedId);

    // The write carries the lost session's member id, because the process was
    // killed before anything cleared it.
    expect(await clockOf(phone, _editedId, 'title'),
        phone.stack.identity.memberIdHex);

    return (phone, container, restore);
  }

  /// The session restore answers "signed out": the app settles the bridge
  /// silent and forgets the member id the killed process left behind.
  Future<void> settleSignedOut(
    StackPhone phone,
    ProviderContainer container,
    Completer<String?> restore,
  ) async {
    restore.complete(null);
    expect(await container.read(authTokenProvider.future), isNull);
    // Let Riverpod deliver the invalidation the answer caused before the
    // provider is read again.
    await Future<void>.delayed(Duration.zero);
    expect(await container.read(syncLifecycleProvider.future), isNull);
    expect((await readClockIdentity(phone.domain)).enrolledMemberIdHex, isNull,
        reason: 'the signed-out settle forgot the member id the killed process '
            'left behind');
  }

  test('a write made before the restore answered survives a rebuild from the '
      'op log', () async {
    final (phone, container, restore) = await lostSessionLaunch();
    await settleSignedOut(phone, container, restore);

    final affected = await phone.stack.defaultClient.rebuildFromOpLog();
    await phone.host!.projector.project(affected);

    final todos = await todosOf(phone);
    expect(todos.map((row) => row['id']), [_editedId, _createdId]);
    expect(todos.firstWhere((row) => row['id'] == _editedId)['title'],
        _editedTitle);
  });

  test('a write made before the restore answered reaches another device once '
      'the account signs back in', () async {
    final (phone, container, restore) = await lostSessionLaunch();
    await settleSignedOut(phone, container, restore);

    expect(await phone.activate(), SyncActivation.active);
    await flush(phone);

    final witness = await phoneNamed('B');
    await witness.enrolWithPassphrase(_passphrase);
    expect(await witness.activate(), SyncActivation.active);

    final todos = await todosOf(witness);
    expect(todos.map((row) => row['id']), [_editedId, _createdId]);
    expect(todos.firstWhere((row) => row['id'] == _editedId)['title'],
        _editedTitle);
    expect(todos.firstWhere((row) => row['id'] == _createdId)['user_id'], _userId,
        reason: 'the account owns a row created before the restore answered');
  });

  test('an enrolled relaunch still authors the write, under the member id',
      () async {
    final (phone, _, _) = await lostSessionLaunch();
    // No settle: the session restore never answers, so the bridge is still
    // undecided and the write is still held rather than dropped.

    expect(await phone.activate(), SyncActivation.active);
    await flush(phone);

    final witness = await phoneNamed('B');
    await witness.enrolWithPassphrase(_passphrase);
    expect(await witness.activate(), SyncActivation.active);

    expect(
        (await todosOf(witness)).firstWhere((row) => row['id'] == _editedId)['title'],
        _editedTitle);
    expect(await clockOf(phone, _editedId, 'title'),
        phone.stack.identity.memberIdHex);
  });
}
