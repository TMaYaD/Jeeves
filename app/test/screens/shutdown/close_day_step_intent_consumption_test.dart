/// Widget tests for the Close Day step's *and-then-plan* intent consumption
/// (issue #460, ADR-0020, ruling 4).
///
/// This is the other half of the sequenced-entry flow pinned by
/// `planning_blocked_start_gate_test.dart`: that test carries the intent
/// from the blocked-start interstitial into `shutdownThenPlanProvider`; this
/// one drives the Close Day step's `_onCloseDay` handler and asserts it (a)
/// clears the intent, (b) resets the planning draft via `reEnterPlanning`,
/// and (c) routes into `/focus-session-planning` instead of exiting the app
/// — with the negative asserted too: no intent means no route into planning.
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
import 'package:jeeves/screens/shutdown/steps/close_day_step.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:jeeves/widgets/app_title_bar/app_title_bar.dart';

import '../../test_helpers.dart';

(Widget, ProviderContainer) _app(GtdDatabase db) {
  final container = ProviderContainer(overrides: [
    databaseProvider.overrideWithValue(db),
    notificationServiceProvider.overrideWithValue(StubNotificationService()),
  ]);
  final router = GoRouter(
    initialLocation: '/shutdown-close-day',
    routes: [
      GoRoute(
        path: '/shutdown-close-day',
        builder: (_, _) => const CloseDayStep(),
      ),
      GoRoute(
        path: '/focus-session-planning',
        builder: (_, _) => const Scaffold(body: Text('focus-session-planning')),
      ),
    ],
  );
  final widget = UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router),
  );
  return (widget, container);
}

/// Pumps past the entrance animation (1600ms) so `_showButton` flips and the
/// Close Day button becomes hit-testable (it is wrapped in an `IgnorePointer`
/// gated on that flag).
Future<void> _revealButton(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 1700));
  await tester.pump();
}

void main() {
  setUpAll(configureSqliteForTests);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
      'Close Day is a structural capture exclusion: it renders no title bar, '
      'so the pinned capture action is absent (#458)', (tester) async {
    final db = GtdDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final (widget, container) = _app(db);
    addTearDown(container.dispose);

    await tester.pumpWidget(widget);
    await tester.pump();

    // The terminal Close Day screen is rendered standalone (not via the shared
    // Wizard), so it carries no AppTitleBar — capture is structurally absent,
    // no suppression logic required.
    expect(find.byType(AppTitleBar), findsNothing);
    expect(find.byKey(const Key('capture_action')), findsNothing);

    // Unmount before the entrance animation leaves a pending timer behind.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
      'and-then-plan intent set: Close Day clears the intent, resets the '
      'planning draft, and routes to /focus-session-planning', (tester) async {
    final db = GtdDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final (widget, container) = _app(db);
    addTearDown(container.dispose);

    // Seed the sequenced-entry intent (as the blocked-start interstitial
    // does) and a stale planning draft that reEnterPlanning must clear.
    container.read(shutdownThenPlanProvider.notifier).set(true);
    container.read(focusSessionPlanningProvider.notifier)
      ..selectTask('stale-task')
      ..goToStep(3);

    expect(container.read(shutdownThenPlanProvider), isTrue);
    expect(
      container.read(focusSessionPlanningProvider).pendingSelectedTaskIds,
      contains('stale-task'),
    );

    await tester.pumpWidget(widget);
    await _revealButton(tester);

    await tester.tap(find.text('Close Day'));
    // Flush the _onCloseDay await chain: closeDay() -> set(false) ->
    // reEnterPlanning() -> context.go(...).
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }

    expect(container.read(shutdownThenPlanProvider), isFalse,
        reason: 'the and-then-plan intent is consumed, not left set');
    expect(
      container.read(focusSessionPlanningProvider).pendingSelectedTaskIds,
      isEmpty,
      reason: 'reEnterPlanning resets the stale planning draft',
    );
    expect(container.read(focusSessionPlanningProvider).currentStep, 0,
        reason: 'reEnterPlanning resets the draft to a fresh performance');
    expect(find.text('focus-session-planning'), findsOneWidget,
        reason: 'Close Day routes into planning instead of exiting the app');
  });

  testWidgets(
      'and-then-plan intent not set: Close Day does NOT route into planning',
      (tester) async {
    final db = GtdDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final (widget, container) = _app(db);
    addTearDown(container.dispose);

    // Intent is false by default; leave a planning draft in place to prove
    // reEnterPlanning is never invoked on this path either.
    container.read(focusSessionPlanningProvider.notifier).selectTask('kept-task');
    expect(container.read(shutdownThenPlanProvider), isFalse);

    await tester.pumpWidget(widget);
    await _revealButton(tester);

    await tester.tap(find.text('Close Day'));
    // Flush closeDay()'s await chain without letting the exit fade-out
    // animation (700ms) complete — it would invoke the real closeApp()
    // platform call, which this test has no need to exercise.
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }

    expect(find.text('focus-session-planning'), findsNothing,
        reason: 'no and-then-plan intent means no route into planning');
    expect(container.read(shutdownThenPlanProvider), isFalse);
    expect(
      container.read(focusSessionPlanningProvider).pendingSelectedTaskIds,
      contains('kept-task'),
      reason: 'reEnterPlanning is never called on the exit path',
    );

    // Unmount before the fade-out animation can complete, so the
    // AnimationController is disposed cleanly instead of racing closeApp().
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
