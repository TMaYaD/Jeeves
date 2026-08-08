/// What the sync indicator says, as a pure table.
///
/// The mapping is the whole risk in `syncStatusProvider`: it is the one stage-2
/// signal the UI is allowed to read, and the flip changed what it reads from. A
/// mapping that reported `synced` over a device with a standing integrity alarm,
/// or over one that has not re-minted its credential, would be a green light on
/// exactly the device that needs a red one.
///
/// **The fixtures below changed meaning with the condition-class taxonomy and are rewritten rather
/// than carried over**: `accused` used to be any standing alarm and is now
/// specifically an *actionable* one, and a device that merely refused an op is
/// no longer an error at all. Left as they were, they would have kept passing
/// while asserting something else.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/providers/sync_status_provider.dart';
import 'package:jeeves/sync/enrolment_state.dart';
import 'package:jeeves/sync/sync_health.dart';

void main() {
  const clean = SyncHealth();
  const busy = SyncHealth(pendingOpCount: 3);

  /// Something of the user's is stuck: the only shape that is an error.
  const accused = SyncHealth(
    unresolvedAlarmCount: 1,
    actionableAlarmCount: 1,
    alarmKinds: {'author_chain_gap'},
  );

  /// The app handled it and nothing is at risk — the band fourteen of the
  /// eighteen kinds live in.
  const handled = SyncHealth(
    unresolvedAlarmCount: 1,
    alarmKinds: {'author_stream_reordered'},
  );

  /// An op this device correctly refused. Worth reading; never an error.
  const refusing = SyncHealth(quarantineCount: 2, reportableQuarantineCount: 2);

  /// A wrap that has not arrived. Neither an error nor worth interrupting for.
  const waitingOnDelivery = SyncHealth(quarantineCount: 1);

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

  SyncIndication indicationOf(
    EnrolmentState enrolment,
    List<SyncHealth> health, {
    bool hasMemberCredential = true,
  }) =>
      syncIndicationFor(
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

    test('an actionable accusation outranks a busy queue', () {
      expect(statusOf(EnrolmentState.enrolled, [busy, accused]),
          SyncStatus.error);
    });

    test('an op this device refused to apply is worth knowing, not an error', () {
      // The app refused the bytes, which is the fail-closed rule working. The
      // user gets to read about it; the icon does not go red for it.
      expect(
        statusOf(EnrolmentState.enrolled, [refusing]),
        SyncStatus.worthKnowing,
      );
    });

    test('a handled condition is worth knowing, not an error', () {
      expect(
        statusOf(EnrolmentState.enrolled, [handled]),
        SyncStatus.worthKnowing,
      );
    });

    test('a wrap that has not arrived is neither', () {
      // Self-healing, and surfaced nowhere: a KeyWrap in flight is not an event.
      final indication = indicationOf(EnrolmentState.enrolled, [waitingOnDelivery]);
      expect(indication.status, SyncStatus.synced);
      expect(indication.hasSomethingToReport, isFalse);
    });

    test('a flush in progress outranks the calm state', () {
      // Transient and more informative in the moment. The account of events is
      // still there when the queue drains — it is the resting state whenever
      // there is history to read.
      expect(
        statusOf(EnrolmentState.enrolled, [busy, handled]),
        SyncStatus.syncing,
      );
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

  group('E4 precedence across the two Workspaces', () {
    // A device is two Workspaces of one User, and this is the bug a
    // single-Workspace test cannot see: calm news from one must never mask a
    // condition in the other that nobody has looked at.
    test('a calm Workspace beside an undecided actionable one renders red', () {
      expect(
        statusOf(EnrolmentState.enrolled, [handled, accused]),
        SyncStatus.error,
      );
    });

    test('and the rule is not order-dependent', () {
      expect(
        statusOf(EnrolmentState.enrolled, [accused, handled]),
        SyncStatus.error,
      );
    });

    test('a refusal in one Workspace beside a clean one is still reachable', () {
      final indication = indicationOf(EnrolmentState.enrolled, [clean, refusing]);
      expect(indication.status, SyncStatus.worthKnowing);
      expect(indication.hasSomethingToReport, isTrue);
    });

    test('the whole six-row table, in order', () {
      expect(statusOf(EnrolmentState.notEnrolled, [accused]), SyncStatus.localOnly);
      expect(statusOf(EnrolmentState.enrolled, [busy, handled, accused]),
          SyncStatus.error);
      expect(
        statusOf(EnrolmentState.enrolled, [busy, handled],
            hasMemberCredential: false),
        SyncStatus.connecting,
      );
      expect(statusOf(EnrolmentState.enrolled, [busy, handled]), SyncStatus.syncing);
      expect(statusOf(EnrolmentState.enrolled, [clean, handled]),
          SyncStatus.worthKnowing);
      expect(statusOf(EnrolmentState.enrolled, [clean, clean]), SyncStatus.synced);
    });
  });

  group('reachability is the health\'s answer, not the status\'s', () {
    test('nothing to report means no entry point', () {
      expect(
        indicationOf(EnrolmentState.enrolled, [clean, clean]).hasSomethingToReport,
        isFalse,
      );
    });

    test('a flush does not withdraw the account of events', () {
      // The tile stays tappable while `syncing` outranks the calm glyph: a
      // surface that vanished for the length of a flush would read as the
      // report having been retracted.
      final indication = indicationOf(EnrolmentState.enrolled, [busy, handled]);
      expect(indication.status, SyncStatus.syncing);
      expect(indication.hasSomethingToReport, isTrue);
    });

    test('an un-enrolled device reports nothing, whatever its store holds', () {
      // It has no log and no peers, so there is no account to give.
      expect(
        indicationOf(EnrolmentState.notEnrolled, [handled]).status,
        SyncStatus.localOnly,
      );
    });
  });
}
