/// The Settings SYNC section, and what Settings must *not* say about sync
/// (issues #595 AC-3, #673).
///
/// Three states, one per thing the user can do next: sign in, set this device
/// up for sync, or sign out. It still says nothing about how sync is *going* —
/// the section used to carry a second presentation of sync state, a "Sync
/// enabled" tile whose `default:` subtitle read "Sync active", which is
/// precisely the untruth the user reported on a device that was syncing nothing.
/// Sync state has exactly one home, the drawer indicator in `app_shell.dart`
/// derived from the op-log spine.
///
/// The enrolment tile is the load-bearing one (#673): now that nothing routes a
/// signed-in, un-enrolled device into the ceremony, this is where the user finds
/// it. Without it, enrolment would be unreachable rather than opt-in.
///
/// The CUTOVER TOOLING section is asserted absent by name and by tile key: it was
/// operator tooling for the #553 cutover and there is no debug gate keeping a
/// copy of it around.
library;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/auth/session_gate.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/screens/settings/settings_screen.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers.dart';

class _StubNotificationService extends NotificationService {
  _StubNotificationService() : super.forTesting();

  @override
  Future<void> scheduleRitualReminder(RitualId ritual, TimeOfDay time) async {}

  @override
  Future<void> cancelRitualReminder(RitualId ritual) async {}

  @override
  Future<void> cancelRecurringRitualReminder(RitualId ritual) async {}

  @override
  Future<void> snoozeRitualReminder(RitualId ritual, int minutes) async {}

  @override
  Future<void> skipTodayRitualReminder(RitualId ritual) async {}

  @override
  Future<void> cancelReminder(int id) async {}

  @override
  Future<void> cancelAll() async {}
}

Future<void> _pumpSettings(WidgetTester tester, SessionGate gate) async {
  // A viewport tall enough to inflate the whole list, so "the section is not
  // there" cannot be confused with "the section is below the fold".
  tester.view.physicalSize = const Size(1200, 6000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  sessionGateNotifier.value = gate;
  addTearDown(() => sessionGateNotifier.value = SessionGate.checking);

  final db = GtdDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      notificationServiceProvider.overrideWithValue(_StubNotificationService()),
    ],
  );
  addTearDown(container.dispose);
  await container.read(syncedPreferencesProvider.future);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    configureSqliteForTests();
    // One case walks all four gate states, so it builds four in-memory stores in
    // sequence. Drift's warning is about several databases sharing one executor,
    // which these do not.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Settings — SYNC offers the one thing to do next', () {
    testWidgets('signed out: an offer to sign in, and no sign-out',
        (tester) async {
      await _pumpSettings(tester, SessionGate.signedOut);

      expect(find.byKey(const Key('sign_in_to_sync_tile')), findsOneWidget);
      expect(find.byKey(const Key('sign_out_tile')), findsNothing);
      expect(find.byKey(const Key('enrolment_ceremony_tile')), findsNothing);
    });

    testWidgets('checking shows the offer rather than claiming a session',
        (tester) async {
      // Restore has not answered yet. An offer is honest; "Sign out" would be a
      // claim about an account the device may not have.
      await _pumpSettings(tester, SessionGate.checking);

      expect(find.byKey(const Key('sign_in_to_sync_tile')), findsOneWidget);
      expect(find.byKey(const Key('sign_out_tile')), findsNothing);
      expect(find.byKey(const Key('enrolment_ceremony_tile')), findsNothing);
    });

    for (final gate in [SessionGate.signedInNotEnrolled, SessionGate.ready]) {
      testWidgets('${gate.name}: a way to sign out, and no sign-in offer',
          (tester) async {
        await _pumpSettings(tester, gate);

        expect(find.byKey(const Key('sign_out_tile')), findsOneWidget);
        expect(find.byKey(const Key('sign_in_to_sync_tile')), findsNothing);
      });
    }

    testWidgets('signed in but not enrolled: the way into the ceremony',
        (tester) async {
      // #673. Nothing routes this device into enrolment any more, so if the
      // tile is not here the ceremony is unreachable and sync can never start.
      await _pumpSettings(tester, SessionGate.signedInNotEnrolled);

      expect(find.byKey(const Key('enrolment_ceremony_tile')), findsOneWidget);
    });

    testWidgets('enrolled: nothing left to set up', (tester) async {
      await _pumpSettings(tester, SessionGate.ready);

      expect(find.byKey(const Key('enrolment_ceremony_tile')), findsNothing);
    });

    testWidgets('no legacy sync-state presentation, in any state',
        (tester) async {
      for (final gate in SessionGate.values) {
        await _pumpSettings(tester, gate);

        expect(find.text('Sync enabled'), findsNothing, reason: gate.name);
        expect(find.text('Sync active'), findsNothing, reason: gate.name);
        expect(find.text('All changes saved'), findsNothing, reason: gate.name);
        expect(find.text('Sync error'), findsNothing, reason: gate.name);
      }
    });
  });

  group('Settings — no cutover tooling', () {
    testWidgets('the section and both tiles are gone', (tester) async {
      await _pumpSettings(tester, SessionGate.ready);

      expect(find.text('CUTOVER TOOLING'), findsNothing);
      expect(find.byKey(const Key('converge_verify_tile')), findsNothing);
      expect(find.byKey(const Key('reseed_tile')), findsNothing);
    });
  });
}
