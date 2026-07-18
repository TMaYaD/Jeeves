/// Widget tests for the ceremony back-navigation contract on the Daily
/// Planning ritual (issue #180, Gap 2).
///
/// System back mirrors the footer Back affordance: it retreats the per-item
/// cursor first, then the step, using the exact callbacks the footer holds.
/// When footer Back is unavailable (step 0, first item — or a completion
/// screen) system back exits the ceremony to the execution home screen
/// (`/focus`, user-titled "Now") and abandons the performance. The abandoned
/// performance's working state persists in memory as a draft that seeds the
/// next performance.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/ceremony_in_progress_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/screens/planning/focus_session_planning_screen.dart';

import '../../test_helpers.dart';

const _skipKey = Key('planning_skip');

/// An Inbox item is a Capture with `clarified_at IS NULL` (ADR-0006).
Future<void> _insertInbox(GtdDatabase db, String id) async {
  final now = DateTime.now();
  await db.captureDao.insertCapture(CapturesCompanion(
    id: Value(id),
    title: Value('Inbox item $id'),
    userId: const Value('local'),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
}

(Widget, GoRouter, ProviderContainer) _app(GtdDatabase db) {
  final container = ProviderContainer(
    overrides: [databaseProvider.overrideWithValue(db)],
  );
  final router = GoRouter(
    initialLocation: '/focus-session-planning',
    routes: [
      GoRoute(
        path: '/focus',
        builder: (_, _) => const Scaffold(body: Text('execution home')),
      ),
      GoRoute(
        path: '/focus-session-planning',
        builder: (_, _) => const FocusSessionPlanningScreen(),
      ),
    ],
  );
  final widget = UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router),
  );
  return (widget, router, container);
}

/// The ritual loads its inbox snapshot through a drift watch-stream, which
/// only emits inside the real async zone. Give it a turn under
/// [WidgetTester.runAsync] before settling the frame.
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pumpAndSettle();
}

/// Unmounts the tree so streaming providers dispose before the end-of-test
/// pending-timer check.
Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(configureSqliteForTests);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Daily Planning — system back contract', () {
    late GtdDatabase db;

    setUp(() => db = GtdDatabase(NativeDatabase.memory()));
    tearDown(() async {
      await db.close();
      focusSessionPlanningCompletionNotifier.value = false;
    });

    testWidgets(
        'system back at step 0, first item exits to the execution home '
        'and abandons the performance', (tester) async {
      await _insertInbox(db, 'i1');
      final (widget, _, container) = _app(db);
      addTearDown(container.dispose);
      await tester.pumpWidget(widget);
      await _settle(tester);

      expect(
        container.read(ceremonyInProgressProvider),
        contains(RitualId.dailyPlanning),
        reason: 'performance is in progress while the wizard is open',
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('execution home'), findsOneWidget);
      expect(
        container.read(ceremonyInProgressProvider),
        isNot(contains(RitualId.dailyPlanning)),
        reason: 'back-exit abandons the performance (ADR-0009 hygiene)',
      );

      await _dispose(tester);
    });

    testWidgets(
        'system back mid-step mirrors footer Back: retreats the item cursor '
        'and stays in-progress', (tester) async {
      await _insertInbox(db, 'i1');
      await _insertInbox(db, 'i2');
      final (widget, _, container) = _app(db);
      addTearDown(container.dispose);
      await tester.pumpWidget(widget);
      await _settle(tester);

      await tester.tap(find.byKey(_skipKey));
      await tester.pumpAndSettle();

      expect(container.read(focusSessionPlanningProvider).inboxNav.index, 1);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(container.read(focusSessionPlanningProvider).inboxNav.index, 0,
          reason: 'system back retreats the per-item cursor like footer Back');
      expect(find.byType(FocusSessionPlanningScreen), findsOneWidget,
          reason: 'the ceremony stays open — no route change');
      expect(
        container.read(ceremonyInProgressProvider),
        contains(RitualId.dailyPlanning),
        reason: 'the performance stays in progress while inside the wizard',
      );

      await _dispose(tester);
    });

    testWidgets('system back from a later step retreats to the previous step',
        (tester) async {
      final (widget, _, container) = _app(db);
      addTearDown(container.dispose);
      await tester.pumpWidget(widget);
      await _settle(tester);

      container.read(focusSessionPlanningProvider.notifier).goToStep(2);
      await tester.pumpAndSettle();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(container.read(focusSessionPlanningProvider).currentStep, 1,
          reason: 'system back mirrors the footer Back step retreat');
      expect(find.byType(FocusSessionPlanningScreen), findsOneWidget);

      await _dispose(tester);
    });

    testWidgets('system back on the completion screen exits to the execution home',
        (tester) async {
      final (widget, _, container) = _app(db);
      addTearDown(container.dispose);
      await tester.pumpWidget(widget);
      await _settle(tester);

      // Step 5 is Today's Schedule — the post-ceremony confirmation rendered
      // outside the wizard.
      container.read(focusSessionPlanningProvider.notifier).goToStep(5);
      await _settle(tester);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('execution home'), findsOneWidget);

      await _dispose(tester);
    });

    testWidgets(
        'an abandoned performance seeds the next one: re-entering resumes at '
        'the same step and item', (tester) async {
      await _insertInbox(db, 'i1');
      await _insertInbox(db, 'i2');
      final (widget, router, container) = _app(db);
      addTearDown(container.dispose);
      await tester.pumpWidget(widget);
      await _settle(tester);

      await tester.tap(find.byKey(_skipKey));
      await tester.pumpAndSettle();

      expect(container.read(focusSessionPlanningProvider).inboxNav.index, 1);

      // Abandon mid-ritual (any exit path — the draft survives in memory).
      router.go('/focus');
      await tester.pumpAndSettle();
      expect(
        container.read(ceremonyInProgressProvider),
        isNot(contains(RitualId.dailyPlanning)),
      );

      // Re-enter: a new performance starts, seeded from the draft.
      router.go('/focus-session-planning');
      await _settle(tester);

      final state = container.read(focusSessionPlanningProvider);
      expect(state.currentStep, 0);
      expect(state.inboxNav.index, 1,
          reason: 'the draft restores the user\'s place in the snapshot');
      expect(
        container.read(ceremonyInProgressProvider),
        contains(RitualId.dailyPlanning),
        reason: 're-entry starts a new in-progress performance',
      );

      await _dispose(tester);
    });
  });
}
