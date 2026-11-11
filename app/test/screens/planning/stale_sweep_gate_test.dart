/// The Stale sweep gate on the Daily Planning route (#107): the wizard is
/// reachable only after the sweep read has succeeded and come back empty.
///
/// Provider overrides drive the read's state deterministically (a real store
/// would hang under FakeAsync, docs/TESTING.md); the sweep decisions
/// themselves are covered against a real store in
/// `test/integration/stale_sweep_journey_test.dart`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/daos/focus_session_dao.dart' show StaleOutcome;
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/stale_sweep_provider.dart';
import 'package:jeeves/screens/planning/focus_session_planning_screen.dart';

import '../../test_helpers.dart';

class _StubPlanningNotifier extends FocusSessionPlanningNotifier {
  @override
  FocusSessionPlanningState build() => const FocusSessionPlanningState();

  @override
  Future<void> loadInboxSnapshot() async {}
}

Future<void> _pump(
  WidgetTester tester,
  Future<List<StaleOutcome>> Function() read,
) async {
  final container = ProviderContainer(overrides: [
    activeSessionProvider.overrideWith((ref) => Stream.value(null)),
    focusSessionPlanningProvider.overrideWith(() => _StubPlanningNotifier()),
    focusSessionPlanningIntroCountsProvider
        .overrideWith((ref) async => (inboxCount: 0, reviewCount: 0)),
    staleOutcomesProvider.overrideWith((ref) => read()),
  ]);
  addTearDown(container.dispose);
  final router = GoRouter(
    initialLocation: '/focus-session-planning',
    routes: [
      GoRoute(
          path: '/focus-session-planning',
          builder: (_, _) => const FocusSessionPlanningScreen()),
      GoRoute(
          path: '/focus',
          builder: (_, _) => const Scaffold(body: Text('home'))),
    ],
  );
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router),
  ));
  await tester.pump();
}

void main() {
  setUpAll(configureSqliteForTests);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a pending read keeps the wizard closed until it is empty',
      (tester) async {
    final read = Completer<List<StaleOutcome>>();
    await _pump(tester, () => read.future);

    expect(find.byKey(const Key('stale_sweep_loading')), findsOneWidget);
    expect(find.text('Daily Planning'), findsNothing);

    read.complete(const []);
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('stale_sweep_loading')), findsNothing);
    expect(find.byKey(const Key('stale_sweep_interstitial')), findsNothing);
    expect(find.text('Daily Planning'), findsWidgets,
        reason: 'an empty successful result lets the wizard start');
  });

  testWidgets('a failed read shows retry and exit, never the wizard',
      (tester) async {
    var attempts = 0;
    final second = Completer<List<StaleOutcome>>();
    await _pump(tester, () {
      attempts++;
      if (attempts == 1) return Future.error(StateError('read failed'));
      return second.future;
    });
    await tester.pump();

    expect(find.byKey(const Key('stale_sweep_error')), findsOneWidget);
    expect(find.text('Daily Planning'), findsNothing);
    expect(find.byKey(const Key('stale_sweep_exit')), findsOneWidget);

    await tester.tap(find.byKey(const Key('stale_sweep_retry')));
    await tester.pump();
    expect(find.text('Daily Planning'), findsNothing,
        reason: 'the retry is pending, the gate stays closed');

    second.complete(const []);
    await tester.pump();
    await tester.pump();
    expect(find.text('Daily Planning'), findsWidgets);
  });
}
