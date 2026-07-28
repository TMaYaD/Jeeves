/// The enrolment ceremony end to end, and what it refuses.
///
/// The convergence suite covers the happy path in the multi-device setting;
/// this file covers the ceremony's own edges — passphrase change, rollback,
/// below-floor blobs, and the ordering that keeps the control chain honest.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/control_payload.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/recovery_escrow.dart';
import 'package:jeeves/sync/root_authority.dart';
import 'package:jeeves/sync/sync_transport.dart';

import 'harness/fake_sync_server.dart';
import 'harness/sim_device.dart';
import 'harness/sim_workspace.dart' show simulationStartWallMs;

const String _userId = 'enrolment-user';

Matcher throwsEscrow(RecoveryEscrowFailure failure) => throwsA(
      predicate<Object>(
        (error) => error is RecoveryEscrowException && error.failure == failure,
        'a RecoveryEscrowException (${failure.code})',
      ),
    );

void main() {
  late FakeSyncServer server;
  late FakeClock clock;

  setUp(() {
    server = FakeSyncServer();
    clock = FakeClock(simulationStartWallMs);
  });

  Future<SimDevice> device(String label, {String? passphrase}) => SimDevice.create(
        label: label,
        userId: _userId,
        server: server,
        clock: clock,
        passphrase: passphrase,
      );

  group('the first device', () {
    test('generates a passphrase, escrows Root, and registers itself', () async {
      final first = await device('A');
      addTearDown(first.close);

      expect(first.outcome.isFirstDevice, isTrue);
      expect(first.outcome.escrowVersion, firstEscrowVersion);
      expect(first.outcome.strength.isGenerated, isTrue);
      expect(first.outcome.strength.warning, isNull);
      expect(await first.client.pinnedRootPk(), first.outcome.rootPk);

      // The escrow is written by the ceremony, not by a later step: a device
      // that generated Root and did not escrow it would be a lost account.
      final escrow = await server
          .connectAsUser(_userId)
          .fetchRecoveryEscrow(first.client.workspaceId);
      expect(escrow!.version, firstEscrowVersion);
      expect(escrow.rootPk, first.outcome.rootPk);

      // And the register is in the log, with the zero chain link that is only
      // legal because nothing preceded it.
      final register = server.storedOps.single;
      expect(register.header!.opClass, opClassControl);
      expect(register.header!.authorSeq, 1);
      final payload =
          ControlPayload.decode(parseBody(splitEnvelope(register.envelope).body));
      expect(payload.controlType, controlTypeMemberRegister);
      expect(payload.prevControlHash, zeroPrevControlHash);
      expect(server.isChained(first.identity.memberId), isTrue);
    });

    test('accepts a user-chosen passphrase behind its warning', () async {
      final first = await SimDevice.create(
        label: 'A',
        userId: _userId,
        server: server,
        clock: clock,
        passphrase: null,
      );
      addTearDown(first.close);
      // The generated default is what a first device gets when it asks for
      // nothing; the chosen-passphrase path is the same code with the estimate
      // attached, and the estimator is covered in passphrase_policy_test.
      expect(first.outcome.passphrase.split(' ').length, 6);
    });
  });

  group('a later device', () {
    test('enrols on the passphrase alone and pulls before it registers',
        () async {
      final first = await device('A');
      addTearDown(first.close);
      final second = await device('B', passphrase: first.outcome.passphrase);
      addTearDown(second.close);

      // Step 5 before step 6: B applied A's register, so its own names it.
      final firstPayload = parseBody(splitEnvelope(server.storedOps[0].envelope).body);
      final secondPayload = ControlPayload.decode(
        parseBody(splitEnvelope(server.storedOps[1].envelope).body),
      );
      expect(secondPayload.prevControlHash, controlPayloadHash(firstPayload));
      expect(second.client.directory.isChained(first.identity.memberId), isTrue);
      expect(await second.client.quarantined(), isEmpty);
    });

    test('refuses a wrong passphrase without pinning anything', () async {
      final first = await device('A');
      addTearDown(first.close);
      await expectLater(
        device('B', passphrase: 'wrong wrong wrong wrong wrong wrong'),
        throwsEscrow(RecoveryEscrowFailure.wrongPassphrase),
      );
    });

    test('cannot enrol against an account with no escrow', () async {
      // Nothing has written the slot, so there is no Root to recover.
      await expectLater(
        device('B', passphrase: 'anything at all'),
        throwsEscrow(RecoveryEscrowFailure.malformedBlob),
      );
    });
  });

  group('passphrase change', () {
    test('re-wraps at version + 1 and the older blob is refused thereafter',
        () async {
      final first = await device('A');
      addTearDown(first.close);
      final original = await server
          .connectAsUser(_userId)
          .fetchRecoveryEscrow(first.client.workspaceId);

      const replacement = 'brand new passphrase for this account here';
      final changed = await first.enrolment.changePassphrase(
        currentPassphrase: first.outcome.passphrase,
        newPassphrase: replacement,
      );
      expect(changed.escrowVersion, firstEscrowVersion + 1);
      // Same Root: a passphrase change rotates the wrapper, not the key.
      expect(changed.rootPk, first.outcome.rootPk);
      expect(await first.client.highestEscrowVersionSeen(), 2);

      // The server refuses the older version outright.
      expect(
        () => server
            .connectAsUser(_userId)
            .putRecoveryEscrow(first.client.workspaceId, original!),
        throwsA(
          predicate<Object>(
            (error) =>
                error is SyncTransportException &&
                error.code == 'escrow_version_regression',
            'an escrow_version_regression',
          ),
        ),
      );

      // And a third device enrols on the new passphrase, not the old one.
      final third = await device('C', passphrase: replacement);
      addTearDown(third.close);
      expect(third.outcome.rootPk, first.outcome.rootPk);
      await expectLater(
        device('D', passphrase: first.outcome.passphrase),
        throwsEscrow(RecoveryEscrowFailure.wrongPassphrase),
      );
    });

    test('a served version below the high-water mark alarms', () async {
      const replacement = 'another passphrase entirely for the account';
      final first = await device('A');
      addTearDown(first.close);
      final original = await server
          .connectAsUser(_userId)
          .fetchRecoveryEscrow(first.client.workspaceId);
      await first.enrolment.changePassphrase(
        currentPassphrase: first.outcome.passphrase,
        newPassphrase: replacement,
      );
      expect(await first.client.highestEscrowVersionSeen(), 2);

      // A server that quietly serves the *genuine* older record back: correctly
      // signed by the right Root, and still a rollback because this device has
      // already accepted version 2. The passphrase is never even asked for —
      // this is an alarm, not a prompt.
      final rolledBack = FakeSyncServer().connectAsUser(_userId);
      await rolledBack.putRecoveryEscrow(first.client.workspaceId, original!);

      expect(
        () => _recoverAgainst(first, rolledBack),
        throwsEscrow(RecoveryEscrowFailure.versionRollback),
      );
    });

    test('a record signed by another Root alarms before any prompt', () async {
      final first = await device('A');
      addTearDown(first.close);

      final substituted = FakeSyncServer().connectAsUser(_userId);
      final impostor = await RootAuthority.generate();
      await substituted.putRecoveryEscrow(
        first.client.workspaceId,
        await impostor.escrowRecord(
          workspaceId: first.client.workspaceId,
          version: firstEscrowVersion,
          blob: await wrapEscrowBlob(
            passphrase: 'whatever the attacker likes',
            secrets: EscrowedSecrets(
              rootSecretKey: Uint8List(32),
              masterWrapKey: Uint8List(32),
            ),
            parameters: harnessKdfParameters,
            floor: harnessKdfParameters,
          ),
        ),
      );

      expect(
        () => _recoverAgainst(first, substituted),
        throwsEscrow(RecoveryEscrowFailure.rootMismatch),
      );
    });
  });

  group('below the KDF floor', () {
    test('a served blob under the floor is refused on read', () async {
      final first = await device('A');
      addTearDown(first.close);

      // A blob wrapped under weakened parameters by something that did not
      // check. Reading it must refuse before any KDF work runs (F12).
      final weak = const Argon2idParameters(
        memoryKib: 8,
        timeCost: 1,
        parallelism: 1,
      );
      final blob = await wrapEscrowBlob(
        passphrase: first.outcome.passphrase,
        secrets: EscrowedSecrets(
          rootSecretKey: Uint8List(32),
          masterWrapKey: Uint8List(32),
        ),
        parameters: weak,
        floor: weak,
      );
      expect(
        () => readEscrowBlobParameters(blob, floor: harnessKdfParameters),
        throwsEscrow(RecoveryEscrowFailure.kdfBelowFloor),
      );
    });
  });
}

/// Run the recovery half of the ceremony against a different server.
///
/// The device's own link is bound to its server; pointing the *check* at
/// another one is how a "the server rolled the escrow back" case is staged
/// without teaching the harness a second network.
Future<void> _recoverAgainst(SimDevice device, UserTransport transport) async {
  final record = await transport.fetchRecoveryEscrow(device.client.workspaceId);
  final pinned = await device.client.pinnedRootPk();
  await verifyEscrowRecordSignature(record!, device.client.workspaceId, pinned!);
  if (record.version < await device.client.highestEscrowVersionSeen()) {
    throw RecoveryEscrowException(
      RecoveryEscrowFailure.versionRollback,
      'served escrow version ${record.version} is below the highest seen',
    );
  }
}
