/// An enrolment that stops after this device's registration is applied in an
/// encrypted Workspace, and before it has adopted that Workspace's epoch keys.
///
/// The device holds keys and is registered everywhere, so nothing else in its
/// store says the ceremony is unfinished — and the encrypted history stays
/// quarantined on it for good. Adoption needs the passphrase (the wraps are
/// opened with the master wrap key, which is never cached), so the only honest
/// answer is to read as unfinished and let the passphrase resume adopt.
///
/// Runs the real ceremony over the real [SyncStack] against the fake server, as
/// `enrolment_ceremony_runner_test.dart` does.
library;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/device_key_store.dart';
import 'package:jeeves/sync/enrolment_state.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:jeeves/sync/sync_stack.dart';
import 'package:jeeves/sync/sync_transport.dart';
import 'package:jeeves/sync/workspace_key_store.dart';

import 'harness/fake_sync_server.dart';
import 'harness/sim_device.dart';
import 'harness/sim_workspace.dart' show simulationStartWallMs;

const String _userId = 'adoption-user';
const String _passphrase = 'correct horse battery staple adoption';

/// One device: its store, its keys, and the stack over them.
///
/// Hand-built rather than taken from `StackPhone`, because this case needs the
/// device to be *reassembled* over its own store — a relaunch — and the
/// harness's own phone holds a domain store and a capture seam this case has
/// no use for.
class _Phone {
  _Phone(this.link, this.database, this.keyStore, this.workspaceKeys);

  late SyncStack stack;
  final DeviceLink link;
  final SyncDatabase database;
  final InMemoryDeviceKeyStore keyStore;
  final InMemoryWorkspaceKeyStore workspaceKeys;
}

void main() {
  late FakeSyncServer server;
  late FakeClock clock;

  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    server = FakeSyncServer();
    clock = FakeClock(simulationStartWallMs);
  });

  Future<SyncStack> assemble(_Phone phone) => SyncStack.assemble(
        userId: _userId,
        database: phone.database,
        keyStore: phone.keyStore,
        workspaceKeys: phone.workspaceKeys,
        userTransport: phone.link,
        nowMs: () => clock.nowMs,
        kdfParameters: harnessKdfParameters,
        kdfFloor: harnessKdfParameters,
      );

  Future<_Phone> phone() async {
    final database = SyncDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final created = _Phone(
      DeviceLink(server.connectAsUser(_userId)),
      database,
      InMemoryDeviceKeyStore(),
      InMemoryWorkspaceKeyStore(),
    );
    created.stack = await assemble(created);
    return created;
  }

  final preferencesWorkspaceId = userPreferencesWorkspaceId(_userId);

  /// A device that founds both Workspaces and encrypts them from genesis, so
  /// there are epoch-0 keys for a joining device to adopt.
  Future<void> enrolFounder() async {
    final founder = await phone();
    await founder.stack.enrolment
        .enrolFirstDevice(passphrase: _passphrase, encryptFromGenesis: true);
  }

  /// A joining device whose enrolment stops between its registration being
  /// applied in the preferences Workspace and its adopting that Workspace's
  /// epoch keys.
  ///
  /// The fault is the epoch-key fetch, which is the last thing the ceremony
  /// does in a Workspace and the only thing that needs the passphrase: the
  /// wraps it would return are opened with the master wrap key, which is never
  /// cached on the device.
  Future<_Phone> joinerStoppedBeforeAdopting() async {
    await enrolFounder();
    final joiner = await phone();
    joiner.link.failNextEpochKeysForWorkspaceId = preferencesWorkspaceId;
    await expectLater(
      joiner.stack.enrolment.enrolWithPassphrase(_passphrase),
      throwsA(isA<SyncTransportException>()),
      reason: 'the epoch-key fetch is the step that fails, and it fails loudly',
    );
    return joiner;
  }

  Future<void> expectHoldsEpochZero(_Phone device) async {
    for (final workspaceId in derivableWorkspaceIds(_userId)) {
      expect(await device.workspaceKeys.highestEpochHeld(workspaceId), 0,
          reason: '$workspaceId was encrypted from genesis and this device '
              'adopted it');
    }
  }

  test('the enrolment stops after the registration is applied and before the '
      'keys are adopted', () async {
    final joiner = await joinerStoppedBeforeAdopting();

    // Registered in both Workspaces, keyed in the default one, unkeyed in the
    // preferences one: the registration landed and the key plane did not.
    expect(await joiner.workspaceKeys.highestEpochHeld(preferencesWorkspaceId),
        isNull);
    expect(await joiner.workspaceKeys.highestEpochHeld(defaultWorkspaceId(_userId)),
        0,
        reason: 'the default Workspace was keyed before the fault fired');
    expect(
        (await joiner.stack.readEnrolmentStatus()).registeredWorkspaceIds,
        contains(preferencesWorkspaceId));
  });

  test('a joining device that stopped before adopting keys reads as unfinished '
      'and the passphrase resume adopts them', () async {
    final joiner = await joinerStoppedBeforeAdopting();

    expect((await joiner.stack.readEnrolmentStatus()).state,
        EnrolmentState.foundingIncomplete,
        reason: 'registered everywhere is not enrolled while a Workspace\'s keys '
            'are unadopted (#993)');

    // A relaunch over the same store reads the same.
    joiner.stack = await assemble(joiner);
    expect((await joiner.stack.readEnrolmentStatus()).state,
        EnrolmentState.foundingIncomplete);

    await joiner.stack.enrolment.enrolWithPassphrase(_passphrase);

    expect((await joiner.stack.readEnrolmentStatus()).state, EnrolmentState.enrolled);
    await expectHoldsEpochZero(joiner);
  });

  test('a device that finished enrolling reads as enrolled and does not adopt '
      'again', () async {
    await enrolFounder();

    final joiner = await phone();
    await joiner.stack.enrolment.enrolWithPassphrase(_passphrase);
    await expectHoldsEpochZero(joiner);

    final fetchesAfterEnrolment = joiner.link.epochKeysFetchCount;
    joiner.stack = await assemble(joiner);
    expect((await joiner.stack.readEnrolmentStatus()).state, EnrolmentState.enrolled);
    expect(joiner.link.epochKeysFetchCount, fetchesAfterEnrolment,
        reason: 'reading the status, and relaunching, never asks for keys');
  });
}
