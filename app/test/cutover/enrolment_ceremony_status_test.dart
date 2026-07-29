/// The state machine behind the ceremony surface, as a branch table.
///
/// Cutover tooling — removed by #556.
///
/// `test/sync/enrolment_ceremony_runner_test.dart` reaches these states by
/// staging real crash windows against a real ceremony; this file pins the whole
/// table, including the combinations a staged failure cannot conveniently
/// produce, so a future edit to the rule has to disagree with something.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/cutover/enrolment_ceremony/enrolment_ceremony_runner.dart';
import 'package:jeeves/sync/recovery_escrow.dart';
import 'package:jeeves/sync/sync_transport.dart';

const List<String> _workspaces = ['default-workspace', 'preferences-workspace'];

final Uint8List _rootPk = Uint8List.fromList([
  0xde, 0xad, 0xbe, 0xef, 0x01, 0x02, 0x03, 0x04, ...List<int>.filled(24, 0),
]);

EnrolmentCeremonyStatus _derive({
  List<String> founded = const [],
  String? memberId,
  Uint8List? pinnedRootPk,
  int escrowVersion = 0,
}) =>
    deriveEnrolmentCeremonyStatus(
      workspaceIds: _workspaces,
      foundedWorkspaceIds: founded,
      storedMemberId: memberId,
      pinnedRootPk: pinnedRootPk,
      highestEscrowVersionSeen: escrowVersion,
    );

void main() {
  group('status derivation', () {
    test('nothing stored at all is not enrolled', () {
      final status = _derive();
      expect(status.state, EnrolmentState.notEnrolled);
      expect(status.memberId, isNull);
      expect(status.rootPkFingerprint, isNull);
      expect(status.escrowVersion, isNull,
          reason: 'version 0 is "never accepted one", not a version');
      expect(status.foundedWorkspaceIds, isEmpty);
    });

    test('a pinned Root with no keys is half-founded, not un-enrolled', () {
      // The ceremony writes the escrow and pins Root *before* it stores the
      // keypairs. Calling this "not enrolled" would offer a founding button whose
      // only possible answer, for ever, is a refusal from the occupied slot.
      final status = _derive(pinnedRootPk: _rootPk, escrowVersion: 1);
      expect(status.state, EnrolmentState.foundingIncomplete);
      expect(status.memberId, isNull);
      expect(status.rootPkFingerprint, 'deadbeef01020304');
      expect(status.escrowVersion, 1);
    });

    test('keys with no founded Workspace is half-founded', () {
      expect(
        _derive(memberId: 'member-1', pinnedRootPk: _rootPk, escrowVersion: 1).state,
        EnrolmentState.foundingIncomplete,
      );
    });

    test('keys with only one Workspace founded is half-founded', () {
      // The preferences Workspace is the one that gets left behind, and a device
      // that called itself enrolled here would never author its genesis.
      final status = _derive(
        memberId: 'member-1',
        pinnedRootPk: _rootPk,
        founded: const ['default-workspace'],
        escrowVersion: 1,
      );
      expect(status.state, EnrolmentState.foundingIncomplete);
      expect(status.foundedWorkspaceIds, ['default-workspace']);
    });

    test('keys plus every Workspace founded is enrolled', () {
      final status = _derive(
        memberId: 'member-1',
        pinnedRootPk: _rootPk,
        founded: _workspaces.reversed.toList(),
        escrowVersion: 2,
      );
      expect(status.state, EnrolmentState.enrolled);
      expect(status.memberId, 'member-1');
      expect(status.escrowVersion, 2);
      // Reported in ceremony order regardless of the order they were observed in.
      expect(status.foundedWorkspaceIds, _workspaces);
    });
  });

  group('failure classification', () {
    test('no response is the un-enrolled failure', () {
      expect(
        classifyEnrolmentCeremonyFailure(
          const SyncTransportException.unreachable('no route to host'),
        ),
        EnrolmentCeremonyFailure.serverUnreachable,
      );
    });

    test('both escrow-PUT refusals mean the account is already founded', () {
      for (final code in [badEscrowSignatureCode, escrowVersionRegressionCode]) {
        expect(
          classifyEnrolmentCeremonyFailure(
            SyncTransportException(code == badEscrowSignatureCode ? 403 : 409,
                'refused', code: code),
          ),
          EnrolmentCeremonyFailure.escrowAlreadyExists,
          reason: code,
        );
      }
    });

    test('a wrong passphrase is the only prompt; the rest are alarms', () {
      expect(
        classifyEnrolmentCeremonyFailure(
          const RecoveryEscrowException(
            RecoveryEscrowFailure.wrongPassphrase,
            'did not authenticate',
          ),
        ),
        EnrolmentCeremonyFailure.wrongPassphrase,
      );
      for (final failure in RecoveryEscrowFailure.values) {
        if (failure == RecoveryEscrowFailure.wrongPassphrase) continue;
        if (failure == RecoveryEscrowFailure.noEscrowStored) continue;
        expect(
          classifyEnrolmentCeremonyFailure(
            RecoveryEscrowException(failure, 'refused'),
          ),
          EnrolmentCeremonyFailure.integrityAlarm,
          reason: failure.code,
        );
      }
    });

    test('an empty slot is its own state, not an alarm', () {
      expect(
        classifyEnrolmentCeremonyFailure(
          const RecoveryEscrowException(
            RecoveryEscrowFailure.noEscrowStored,
            'nothing to enrol against',
          ),
        ),
        EnrolmentCeremonyFailure.missingEscrow,
      );
    });

    test('this surface\'s own refusal is not dressed up as a server failure', () {
      expect(
        classifyEnrolmentCeremonyFailure(
          const EnrolmentCeremonyRefusal('already enrolled'),
        ),
        EnrolmentCeremonyFailure.refused,
      );
      expect(
        enrolmentCeremonyFailureMessage(
          EnrolmentCeremonyFailure.refused,
          const EnrolmentCeremonyRefusal('already enrolled'),
        ),
        contains('already enrolled'),
      );
    });

    test('anything else is shown raw rather than guessed at', () {
      final error = StateError('the store went away');
      expect(
        classifyEnrolmentCeremonyFailure(error),
        EnrolmentCeremonyFailure.unknown,
      );
      expect(
        enrolmentCeremonyFailureMessage(EnrolmentCeremonyFailure.unknown, error),
        contains('the store went away'),
      );
      // Every 409 is not an escrow conflict, and a generic 500 is not either.
      expect(
        classifyEnrolmentCeremonyFailure(
          const SyncTransportException(500, 'boom'),
        ),
        EnrolmentCeremonyFailure.unknown,
      );
    });
  });
}
