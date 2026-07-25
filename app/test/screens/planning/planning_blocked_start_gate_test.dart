/// Widget test for the Daily Planning blocked-start gate (issue #460,
/// ADR-0020, ruling 4).
///
/// Entering the planning ceremony while a session is open must surface the
/// Shutdown-first interstitial rather than the wizard, and its primary action
/// must carry the and-then-plan intent into Evening Shutdown.
///
/// Uses provider overrides (a plain `Stream.value` for the active session and a
/// stub planning notifier) so the test drives the gate deterministically
/// without the real Drift watch-streams — which only emit under `runAsync` and
/// make a full-wizard `pumpAndSettle` intractable.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/screens/planning/focus_session_planning_screen.dart';
import '../../test_helpers.dart';

/// Stub: skips the rollover preload and no-ops the inbox-snapshot load so the
/// transient wizard frame (before the active-session stream resolves) does not
/// start real DB work.
class _StubPlanningNotifier extends FocusSessionPlanningNotifier {
  @override
  FocusSessionPlanningState build() => const FocusSessionPlanningState();

  @override
  Future<void> loadInboxSnapshot() async {}
}

FocusSession _openSession() => FocusSession(
      id: 'open',
      userId: 'local',
      startedAt: DateTime.now().toIso8601String(),
      endedAt: null,
      currentTaskId: null,
    );

void main() {
  setUpAll(configureSqliteForTests);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
      'open session → interstitial, and "Begin Evening Shutdown" carries the '
      'and-then-plan intent to /shutdown', (tester) async {
    final db = GtdDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      activeSessionProvider.overrideWith((ref) => Stream.value(_openSession())),
      focusSessionPlanningProvider.overrideWith(() => _StubPlanningNotifier()),
      // The transient wizard frame (before the active-session stream resolves)
      // now opens on the duration-estimate intro (#486), which would otherwise
      // start real Drift reads that never settle under this fake-async test.
      // Stub the counts so that frame does no DB work — mirroring the notifier
      // stub's no-op loadInboxSnapshot.
      focusSessionPlanningIntroCountsProvider
          .overrideWith((ref) async => (inboxCount: 0, reviewCount: 0)),
    ]);
    addTearDown(container.dispose);

    final router = GoRouter(
      initialLocation: '/focus-session-planning',
      routes: [
        GoRoute(
            path: '/focus-session-planning',
            builder: (_, _) => const FocusSessionPlanningScreen()),
        GoRoute(
            path: '/shutdown',
            builder: (_, _) => const Scaffold(body: Text('shutdown'))),
        GoRoute(
            path: '/focus',
            builder: (_, _) => const Scaffold(body: Text('home'))),
      ],
    );

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    // Let the Stream.value active-session override emit (fake-async friendly).
    await tester.pump();
    await tester.pump();

    expect(find.text('Close your current session first'), findsOneWidget);
    expect(find.text('Begin Evening Shutdown'), findsOneWidget);
    expect(container.read(shutdownThenPlanProvider), isFalse);

    await tester.tap(find.text('Begin Evening Shutdown'));
    await tester.pump();
    await tester.pump();

    expect(container.read(shutdownThenPlanProvider), isTrue,
        reason: 'the and-then-plan intent is carried into Evening Shutdown');
    expect(find.text('shutdown'), findsOneWidget);
  });
}
