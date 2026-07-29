/// The enrolment ceremony as the phone runs it: the real runner, over the real
/// [SyncStack], against the harness's fake server.
///
/// **This is the closest thing to the on-device path that runs in CI**, and it is
/// deliberately not a `SimDevice` test. A `SimDevice` hands every one of its
/// clients the same omnipresent `DeviceLink` at construction, so it can never
/// notice a production stack that fails to propagate the member transport to the
/// preferences Workspace's client — the one place production diverges from the
/// harness. Here the ceremony runs through `SyncStack`'s own factory closure, so
/// that propagation is under test rather than assumed.
///
/// The fake server is contract-tested case-for-case against `backend/app/sync/`,
/// which is what makes assertions about "the escrow landed server-side" evidence
/// about the real routes.
library;

import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/cutover/enrolment_ceremony/enrolment_ceremony_runner.dart';
import 'package:jeeves/sync/device_key_store.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/recovery_escrow.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:jeeves/sync/sync_stack.dart';
import 'package:jeeves/sync/sync_transport.dart';

import 'harness/fake_sync_server.dart';
import 'harness/sim_device.dart';
import 'harness/sim_workspace.dart' show simulationStartWallMs;

const String _userId = 'ceremony-user';

/// A [UserTransport] that fails on demand, so the ceremony's crash windows are
/// staged against the production code path rather than described in a comment.
///
/// A decorator over the harness link — the same pattern `SimDevice.enrolmentAgainst`
/// uses — because the ceremony's recovery behaviour is only interesting if
/// everything except the injected fault is the real thing.
class _FaultyUserTransport implements UserTransport {
  _FaultyUserTransport(this._inner);

  final UserTransport _inner;

  /// How many more `POST /members` calls to fail. Counted down rather than
  /// latched, so a resume can succeed where the first attempt did not. Set after
  /// the stack is assembled, which is also when a test knows the Workspace ids.
  int failRegisterMemberTimes = 0;

  /// One-shot: fail the escrow PUT for this Workspace once. Aimed at the
  /// preferences slot, which is written *after* the default slot has been
  /// claimed and Root pinned and *before* the keypairs are stored.
  String? failEscrowPutForWorkspaceId;

  @override
  Future<MemberRecord> registerMember({
    required String memberId,
    required Uint8List signPk,
    required Uint8List kexPk,
  }) async {
    if (failRegisterMemberTimes > 0) {
      failRegisterMemberTimes--;
      throw const SyncTransportException(500, 'member registration exploded');
    }
    return _inner.registerMember(memberId: memberId, signPk: signPk, kexPk: kexPk);
  }

  @override
  Future<RecoveryEscrowRecord?> fetchRecoveryEscrow(String workspaceId) =>
      _inner.fetchRecoveryEscrow(workspaceId);

  @override
  Future<RecoveryEscrowRecord> putRecoveryEscrow(
    String workspaceId,
    RecoveryEscrowRecord record,
  ) async {
    if (workspaceId == failEscrowPutForWorkspaceId) {
      failEscrowPutForWorkspaceId = null;
      throw const SyncTransportException(500, 'escrow slot write exploded');
    }
    return _inner.putRecoveryEscrow(workspaceId, record);
  }

  @override
  Future<Uint8List> requestMemberChallenge(String memberId) =>
      _inner.requestMemberChallenge(memberId);

  @override
  Future<SyncTransport> completeMemberChallenge({
    required String memberId,
    required Uint8List nonce,
    required Uint8List signature,
  }) =>
      _inner.completeMemberChallenge(
        memberId: memberId,
        nonce: nonce,
        signature: signature,
      );
}

/// One phone: its own store, its own key store, its own link to the server.
class _CeremonyDevice {
  _CeremonyDevice({
    required this.stack,
    required this.runner,
    required this.link,
    required this.keyStore,
    required this.faults,
  });

  final SyncStack stack;
  final EnrolmentCeremonyRunner runner;
  final DeviceLink link;
  final InMemoryDeviceKeyStore keyStore;
  final _FaultyUserTransport faults;
}

void main() {
  late FakeSyncServer server;
  late FakeClock clock;

  setUp(() {
    // Every device here owns its own in-memory store, so there is nothing to
    // race — Drift's warning is about several databases over one executor.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    server = FakeSyncServer();
    clock = FakeClock(simulationStartWallMs);
  });

  Future<_CeremonyDevice> phone() async {
    final database = SyncDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final keyStore = InMemoryDeviceKeyStore();
    final link = DeviceLink(server.connectAsUser(_userId));
    final faults = _FaultyUserTransport(link);
    // Assembled exactly as `syncStackProvider` assembles it, with the platform
    // parts swapped for the harness's: the store, the key store, the User
    // transport and the clock. Everything between — identity, HLC, the clients,
    // the memoising factory, the `EnrolmentService` — is the production code.
    final stack = await SyncStack.assemble(
      userId: _userId,
      database: database,
      keyStore: keyStore,
      userTransport: faults,
      nowMs: () => clock.nowMs,
      // Both, so the floor check runs on the production path at a cost a test
      // suite can afford.
      kdfParameters: harnessKdfParameters,
      kdfFloor: harnessKdfParameters,
    );
    return _CeremonyDevice(
      stack: stack,
      runner: StackEnrolmentCeremonyRunner(() async => stack),
      link: link,
      keyStore: keyStore,
      faults: faults,
    );
  }

  test('a fresh device founds the account and reads back as enrolled', () async {
    final device = await phone();

    expect((await device.runner.status()).state, EnrolmentState.notEnrolled);

    final passphrase = await device.runner.generatePassphrase();
    expect(passphrase.split(' ').length, 6);

    final outcome = await device.runner.found(passphrase);
    expect(outcome.passphrase, passphrase);
    expect(outcome.isFirstDevice, isTrue);
    expect(outcome.escrowVersion, firstEscrowVersion);
    expect(outcome.strength.warning, isNull,
        reason: 'a generated phrase re-estimated must not warn');

    // The escrow landed in **both** slots, which is the state the server needs to
    // verify a control op in either Workspace.
    final user = server.connectAsUser(_userId);
    for (final workspaceId in derivableWorkspaceIds(_userId)) {
      final escrow = await user.fetchRecoveryEscrow(workspaceId);
      expect(escrow?.version, firstEscrowVersion, reason: workspaceId);
      expect(escrow?.rootPk, outcome.rootPk, reason: workspaceId);
    }

    final status = await device.runner.status();
    expect(status.state, EnrolmentState.enrolled);
    expect(status.memberId, device.stack.identity.memberId);
    expect(status.escrowVersion, firstEscrowVersion);
    expect(status.rootPkFingerprint, isNotNull);
    // Both Workspaces applied their genesis and the owner Grant. The preferences
    // half is the assertion that fails if the member transport is attached at
    // construction instead of on every factory call: the preferences client is
    // first built at ceremony step 2, before any member credential exists, so a
    // one-shot attach leaves it un-enrolled and step 6's pull throws.
    expect(status.foundedWorkspaceIds, derivableWorkspaceIds(_userId));
    expect(device.stack.defaultClient.isEnrolled, isTrue);
    expect(
      (await device.stack
              .workspaceClientFactory(userPreferencesWorkspaceId(_userId)))
          .isEnrolled,
      isTrue,
    );
  });

  test('an enrolled device refuses a second founding, and writes nothing',
      () async {
    final device = await phone();
    await device.runner.found(await device.runner.generatePassphrase());
    final opsAfterFounding = server.storedOps.length;

    await expectLater(
      device.runner.found('unrelated passphrase words here now please'),
      throwsA(isA<EnrolmentCeremonyRefusal>()),
    );

    expect(server.storedOps.length, opsAfterFounding);
    final user = server.connectAsUser(_userId);
    expect(
      (await user.fetchRecoveryEscrow(defaultWorkspaceId(_userId)))?.version,
      firstEscrowVersion,
    );
    expect((await device.runner.status()).state, EnrolmentState.enrolled);
  });

  test('a server that never answered leaves the device un-enrolled', () async {
    final device = await phone();
    device.link.online = false;

    await expectLater(
      device.runner.found(await device.runner.generatePassphrase()),
      throwsA(
        isA<SyncTransportException>()
            .having((error) => error.isUnreachable, 'isUnreachable', isTrue),
      ),
    );

    expect(await device.keyStore.read(defaultWorkspaceId(_userId)), isNull);
    expect(await device.stack.defaultClient.pinnedRootPk(), isNull);
    expect((await device.runner.status()).state, EnrolmentState.notEnrolled);
    expect(server.storedOps, isEmpty);
  });

  test('a ceremony that died after registering resumes on the same passphrase',
      () async {
    final device = await phone();
    device.faults.failRegisterMemberTimes = 1;
    final passphrase = await device.runner.generatePassphrase();

    await expectLater(
      device.runner.found(passphrase),
      throwsA(isA<SyncTransportException>()),
    );

    // Keys were stored (step 3) before `POST /members` (step 4) failed, and no
    // Workspace was founded — half-founded, and named as such.
    final interrupted = await device.runner.status();
    expect(interrupted.state, EnrolmentState.foundingIncomplete);
    expect(interrupted.memberId, device.stack.identity.memberId);
    expect(interrupted.foundedWorkspaceIds, isEmpty);
    expect(interrupted.escrowVersion, firstEscrowVersion);

    // Founding again cannot help — the escrow is already claimed — so the
    // surface refuses it and points at the passphrase instead.
    await expectLater(
      device.runner.found(passphrase),
      throwsA(isA<EnrolmentCeremonyRefusal>()),
    );

    final resumed = await device.runner.resume(passphrase);
    expect(resumed.isFirstDevice, isFalse);
    expect(resumed.escrowVersion, firstEscrowVersion);

    final status = await device.runner.status();
    expect(status.state, EnrolmentState.enrolled);
    expect(status.memberId, device.stack.identity.memberId);
    expect(status.foundedWorkspaceIds, derivableWorkspaceIds(_userId));
  });

  test('a crash before the keys were stored still reads as half-founded',
      () async {
    final device = await phone();
    // The preferences slot is written after the default slot's PUT and pin and
    // before `keyStore.write`, so failing it stages the pre-keys window exactly.
    device.faults.failEscrowPutForWorkspaceId = userPreferencesWorkspaceId(_userId);
    final passphrase = await device.runner.generatePassphrase();

    await expectLater(
      device.runner.found(passphrase),
      throwsA(isA<SyncTransportException>()),
    );

    // No keys at all, and yet the account's escrow is claimed. Reading this as
    // "not enrolled" would offer a founding button whose only possible answer is
    // `escrow_version_regression` for ever.
    expect(await device.keyStore.read(defaultWorkspaceId(_userId)), isNull);
    final interrupted = await device.runner.status();
    expect(interrupted.state, EnrolmentState.foundingIncomplete);
    expect(interrupted.memberId, isNull);
    expect(interrupted.rootPkFingerprint, isNotNull);

    final resumed = await device.runner.resume(passphrase);
    expect(resumed.escrowVersion, firstEscrowVersion);
    final status = await device.runner.status();
    expect(status.state, EnrolmentState.enrolled);
    expect(status.foundedWorkspaceIds, derivableWorkspaceIds(_userId));
  });

  test('founding against an account that already has an escrow is typed',
      () async {
    final founder = await phone();
    await founder.runner.found(await founder.runner.generatePassphrase());

    final second = await phone();
    expect((await second.runner.status()).state, EnrolmentState.notEnrolled);

    // The refusal is the *signature* one, not the version one: the second phone
    // minted its own Root, and the server checks the record against the `root_pk`
    // already in the slot before it looks at versions. Both codes classify as
    // "already founded" for exactly that reason.
    Object? refusal;
    try {
      await second.runner.found(await second.runner.generatePassphrase());
    } catch (error) {
      refusal = error;
    }
    expect(refusal, isA<SyncTransportException>());
    expect((refusal! as SyncTransportException).code, badEscrowSignatureCode);
    expect(
      classifyEnrolmentCeremonyFailure(refusal),
      EnrolmentCeremonyFailure.escrowAlreadyExists,
    );
    expect(
      classifyEnrolmentCeremonyFailure(
        const SyncTransportException(409, 'conflict',
            code: escrowVersionRegressionCode),
      ),
      EnrolmentCeremonyFailure.escrowAlreadyExists,
    );
    expect((await second.runner.status()).state, EnrolmentState.notEnrolled,
        reason: 'a refused PUT pins nothing, so a passphrase-resume is still open');
  });

  test('a second phone enrols on the passphrase alone', () async {
    final founder = await phone();
    final passphrase = await founder.runner.generatePassphrase();
    await founder.runner.found(passphrase);

    final second = await phone();
    final outcome = await second.runner.resume(passphrase);

    expect(outcome.isFirstDevice, isFalse);
    final status = await second.runner.status();
    expect(status.state, EnrolmentState.enrolled);
    expect(status.memberId, second.stack.identity.memberId);
    expect(status.memberId, isNot(founder.stack.identity.memberId));
    expect(status.foundedWorkspaceIds, derivableWorkspaceIds(_userId));
  });
}
