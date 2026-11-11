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

import '../../helpers/settle.dart';
import '../../support/planning_ceremony_test_helpers.dart';
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
/// only emits inside the real async zone. Drain that queue (no wall-clock
/// sleep) before settling the frame — see [settleWithRealAsync].
Future<void> _settle(WidgetTester tester) => settleWithRealAsync(tester);

/// The text the clarify card currently holds in its title field.
String _titleText(WidgetTester tester) =>
    tester
        .widget<TextField>(find.byKey(const Key('clarify_title')))
        .controller
        ?.text ??
    '';

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
    });

    testWidgets(
        'system back on the intro (step 0) exits to the execution home '
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
        reason: 'back-exit abandons the performance (in-progress hygiene)',
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
      await advancePastIntro(tester, container);

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

      // Energy Check-in (step 3) — a later step with no per-item cursor.
      container.read(focusSessionPlanningProvider.notifier).goToStep(3);
      await tester.pumpAndSettle();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(container.read(focusSessionPlanningProvider).currentStep, 2,
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

      // Step 6 is Today's Schedule — the post-ceremony confirmation rendered
      // outside the wizard (step 0 is the intro; 1–5 the working steps).
      container.read(focusSessionPlanningProvider.notifier).goToStep(6);
      await _settle(tester);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('execution home'), findsOneWidget);

      await _dispose(tester);
    });

    testWidgets(
        'typing on a Capture survives crossing a step boundary and coming '
        'back', (tester) async {
      // Crossing a step boundary disposes the whole page — a wider unmount
      // than the ValueKey teardown clarify_step_test.dart covers, and one the
      // retention store has to survive now that a Capture's text is never
      // written (ADR-0023).
      await _insertInbox(db, 'i1');
      final (widget, _, container) = _app(db);
      addTearDown(container.dispose);
      await tester.pumpWidget(widget);
      await _settle(tester);
      await advancePastIntro(tester, container);

      await tester.enterText(
          find.byKey(const Key('clarify_title')), 'Buy oat milk');
      await tester.pump();

      // Drop focus first, and not for tidiness: `EditableText` keeps its page
      // alive while it holds focus (AutomaticKeepAliveClientMixin), so a
      // still-focused field leaves the whole step mounted off-screen and the
      // card's State simply survives the crossing. The assertion would then
      // hold with the stash deleted — this line is what makes the test
      // falsifiable.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      // Forward into Review Tasks (step 2).
      container.read(focusSessionPlanningProvider.notifier).advanceStep();
      await settleAcrossTransition(tester);
      expect(
          find.byKey(const Key('clarify_title'), skipOffstage: false),
          findsNothing,
          reason: 'the step really is gone — otherwise the return below '
              'proves nothing');

      // …and back to Clarify Inbox.
      container.read(focusSessionPlanningProvider.notifier).goToStep(1);
      await settleAcrossTransition(tester);

      expect(_titleText(tester), 'Buy oat milk');
      expect((await db.captureDao.getCapture('i1'))!.title, 'Inbox item i1',
          reason: 'and the Capture itself was never rewritten (ADR-0023)');

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
      await advancePastIntro(tester, container);

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

      // Re-enter: the draft survives, so the performance resumes mid-ritual on
      // Clarify Inbox (step 1) — the intro shows only on a fresh performance.
      // The route push animates and Clarify Inbox reloads once visible, so
      // drain across the transition rather than pumpAndSettle (which hangs on
      // the in-flight load).
      router.go('/focus-session-planning');
      await settleAcrossTransition(tester);

      final state = container.read(focusSessionPlanningProvider);
      expect(state.currentStep, 1);
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
