/// What the sync indicator says, as a pure table.
///
/// The mapping is the whole risk in `syncStatusProvider`: it is the one stage-2
/// signal the UI is allowed to read, and the flip changed what it reads from. A
/// mapping that reported `synced` over a device with a standing integrity alarm,
/// or over one that has not re-minted its credential, would be a green light on
/// exactly the device that needs a red one.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/providers/sync_status_provider.dart';
import 'package:jeeves/sync/enrolment_state.dart';
import 'package:jeeves/sync/sync_health.dart';

void main() {
  const clean = SyncHealth();
  const busy = SyncHealth(pendingOpCount: 3);
  const accused = SyncHealth(
    unresolvedAlarmCount: 1,
    alarmKinds: {'author_chain_gap'},
  );
  const refusing = SyncHealth(quarantineCount: 2);

  SyncStatus statusOf(
    EnrolmentState enrolment,
    List<SyncHealth> health, {
    bool hasMemberCredential = true,
  }) =>
      syncStatusFor(
        enrolment: enrolment,
        hasMemberCredential: hasMemberCredential,
        health: health,
      );

  group('before a device is enrolled', () {
    test('an un-enrolled device is local only, whatever the health says', () {
      expect(
        statusOf(EnrolmentState.notEnrolled, [busy]),
        SyncStatus.localOnly,
      );
    });

    test('a half-founded device is local only too', () {
      // It has no log its next ceremony will continue, so it is not "connecting".
      expect(
        statusOf(EnrolmentState.foundingIncomplete, [clean]),
        SyncStatus.localOnly,
      );
    });
  });

  group('once enrolled', () {
    test('no member credential yet reads as connecting', () {
      expect(
        statusOf(EnrolmentState.enrolled, [clean], hasMemberCredential: false),
        SyncStatus.connecting,
      );
    });

    test('a drained queue on both Workspaces is synced', () {
      expect(statusOf(EnrolmentState.enrolled, [clean, clean]),
          SyncStatus.synced);
    });

    test('a queue on *either* Workspace is syncing', () {
      // A device is two Workspaces of one User: a wedged preferences queue is a
      // wedged device, and reporting only the default one would hide it.
      expect(statusOf(EnrolmentState.enrolled, [clean, busy]),
          SyncStatus.syncing);
    });

    test('a standing accusation outranks a busy queue', () {
      expect(statusOf(EnrolmentState.enrolled, [busy, accused]),
          SyncStatus.error);
    });

    test('an op this device refused to apply is an error too', () {
      // Not a transport problem, and not something a retry clears: the user is
      // owed an explanation.
      expect(statusOf(EnrolmentState.enrolled, [refusing]), SyncStatus.error);
    });

    test('an accusation outranks a missing credential', () {
      expect(
        statusOf(EnrolmentState.enrolled, [accused],
            hasMemberCredential: false),
        SyncStatus.error,
      );
    });

    test('health not read yet is not reported as an error', () {
      // The seeded first emission happens before any watch stream has fired.
      expect(statusOf(EnrolmentState.enrolled, const []), SyncStatus.synced);
    });
  });
}
