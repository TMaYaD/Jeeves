// Journey for a Daily Planning left unfinished: its Nudge comes back at once in
// continue wording even after a swipe, while leaving from the intro alone
// changes nothing.
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/evening_shutdown_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/ceremony_in_progress_provider.dart';
import 'package:jeeves/providers/nudge_triggers.dart';
import 'package:jeeves/screens/planning/focus_session_planning_screen.dart';
import 'package:jeeves/services/nudge_notification_scheduler.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/router.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/periodic_review_test_helpers.dart';
import '../test_helpers.dart';

// The banner pulses indefinitely; drain real database work without waiting
// for animations to settle.
Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ProviderContainer c;
  late DateTime noon;

  final banner = find.byKey(const Key('planning_banner_visible'));
  final unfinishedLine = find.text('Daily Planning, sir. Unfinished.');
  final shutdownBanner = find.byKey(const Key('shutdown_banner_visible'));
  final shutdownUnfinishedLine =
      find.text('Evening Shutdown, sir. Unfinished.');
  final reviewBanner = find.byKey(const Key('periodic_review_banner_visible'));
  final emptyState = find.byKey(const Key('nudge_empty_state'));
  final emptyStateButton = find.byKey(const Key('nudge_empty_state_button'));

  Future<void> goTo(WidgetTester tester, String location) async {
    appRouter.go(location);
    await _flush(tester);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 100));
    await _flush(tester);
  }

  Future<void> pumpApp(WidgetTester tester) async {
    appRouter.go('/inbox');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp.router(routerConfig: appRouter),
    ));
    await _flush(tester);
  }

  Future<void> tearDownApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      c.dispose();
      await pumpEventQueue();
    });
  }

  /// Starts Daily Planning past the intro and leaves it.
  Future<void> startAndLeavePlanning(WidgetTester tester) async {
    await goTo(tester, '/focus-session-planning');
    c.read(focusSessionPlanningProvider.notifier).goToStep(2);
    await goTo(tester, '/inbox');
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    final today = DateTime.now();
    noon = DateTime(today.year, today.month, today.day, 12);
    c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      // Never earlier than the wall clock: a swipe stamps the wall clock.
      clockProvider.overrideWithValue(
          () => DateTime.now().isAfter(noon) ? DateTime.now() : noon),
      notificationServiceProvider
          .overrideWithValue(StubPeriodicReviewNotificationService()),
    ]);
    await c.read(syncedPreferencesProvider.future);
    await db.into(db.todos).insert(TodosCompanion(
          id: const Value('next-1'),
          title: const Value('Something to do'),
          userId: const Value('local'),
          intent: const Value('next'),
          createdAt: Value(noon.subtract(const Duration(days: 3))),
          updatedAt: Value(noon.subtract(const Duration(days: 3))),
        ));
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets(
      'leaving Daily Planning after proceeding brings the swiped Nudge back in '
      'continue wording; leaving from the intro does not', (tester) async {
    try {
      appRouter.go('/inbox');
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp.router(routerConfig: appRouter),
      ));
      await _flush(tester);
      expect(banner, findsOneWidget);
      expect(unfinishedLine, findsNothing, reason: 'start wording first');

      await tester.drag(banner, const Offset(-300, 0));
      await _flush(tester);
      expect(banner, findsNothing);

      // Opening the intro and leaving is not a start.
      await goTo(tester, '/focus-session-planning');
      expect(banner, findsNothing, reason: 'hidden while the Ceremony is open');
      await goTo(tester, '/inbox');
      expect(banner, findsNothing);

      // Proceeding past the intro and leaving is.
      await goTo(tester, '/focus-session-planning');
      c.read(focusSessionPlanningProvider.notifier).goToStep(2);
      await goTo(tester, '/inbox');
      expect(banner, findsOneWidget);
      expect(unfinishedLine, findsOneWidget);
      expect(find.textContaining('Push on'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        c.dispose();
        await pumpEventQueue();
      });
    }
  });

  testWidgets(
      'an unfinished Daily Planning shows on the Now screen as the empty-state '
      'nudge, never a Banner, and its button reopens the Ceremony',
      (tester) async {
    try {
      await pumpApp(tester);
      await startAndLeavePlanning(tester);
      expect(unfinishedLine, findsOneWidget);

      await goTo(tester, '/focus');
      expect(banner, findsNothing, reason: 'the Now screen carries no Banner');
      expect(emptyState, findsOneWidget);
      expect(unfinishedLine, findsOneWidget);

      await tester.tap(emptyStateButton);
      await _flush(tester);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(FocusSessionPlanningScreen), findsOneWidget);
    } finally {
      await tearDownApp(tester);
    }
  });

  testWidgets(
      'a session opening finishes Daily Planning: the unfinished Nudge is gone '
      'and stays gone after the session closes', (tester) async {
    try {
      await pumpApp(tester);
      await startAndLeavePlanning(tester);
      expect(unfinishedLine, findsOneWidget);

      final sessionId =
          await db.focusSessionDao.openSession(userId: 'local', taskIds: []);
      await _flush(tester);
      expect(unfinishedLine, findsNothing);

      await db.focusSessionDao.closeSession(sessionId: sessionId);
      await _flush(tester);
      expect(unfinishedLine, findsNothing,
          reason: 'next period starts in start wording');
    } finally {
      await tearDownApp(tester);
    }
  });

  testWidgets(
      'Evening Shutdown left unfinished before its anchor shows the continue '
      'Nudge; closing the session clears it and a new session starts clean',
      (tester) async {
    final firstId =
        await db.focusSessionDao.openSession(userId: 'local', taskIds: []);
    try {
      await pumpApp(tester);
      expect(shutdownBanner, findsNothing, reason: 'before the anchor');

      await goTo(tester, '/shutdown');
      await tester.runAsync(() =>
          c.read(eveningShutdownProvider.notifier).markStarted());
      await goTo(tester, '/inbox');
      expect(shutdownBanner, findsOneWidget);
      expect(shutdownUnfinishedLine, findsOneWidget);
      expect(find.textContaining('Push on'), findsOneWidget);

      await db.focusSessionDao.closeSession(sessionId: firstId);
      await _flush(tester);
      expect(shutdownBanner, findsNothing);

      // A later session, started and left, fires again against its own id.
      await db.focusSessionDao.openSession(userId: 'local', taskIds: []);
      await _flush(tester);
      expect(shutdownBanner, findsNothing);
      await goTo(tester, '/shutdown');
      await tester.runAsync(() =>
          c.read(eveningShutdownProvider.notifier).markStarted());
      await goTo(tester, '/inbox');
      expect(shutdownUnfinishedLine, findsOneWidget);
    } finally {
      await tearDownApp(tester);
    }
  });

  testWidgets(
      'a due Weekly Review outranks an unfinished Daily Planning until swiped',
      (tester) async {
    await db.captureDao.insertCapture(CapturesCompanion(
      id: const Value('inbox'),
      title: const Value('Plan this'),
      userId: const Value('local'),
      createdAt: Value(noon.subtract(const Duration(days: 20))),
      updatedAt: Value(noon.subtract(const Duration(days: 20))),
    ));
    await c.read(syncedPreferencesProvider.notifier).set(
        'periodic_review_last_completed_at',
        noon.subtract(const Duration(days: 10)).toIso8601String());
    try {
      await pumpApp(tester);
      await startAndLeavePlanning(tester);
      expect(reviewBanner, findsOneWidget);
      expect(banner, findsNothing);

      await tester.drag(reviewBanner, const Offset(-300, 0));
      await _flush(tester);
      expect(banner, findsOneWidget);
      expect(unfinishedLine, findsOneWidget);
    } finally {
      await tearDownApp(tester);
    }
  });

  test('entering and leaving a Ceremony touches no OS Notification and '
      'leaves the planner output unchanged', () async {
    final service = RecordingNotificationService();
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => noon),
      notificationServiceProvider.overrideWithValue(service),
      nudgeNotificationDebounceProvider.overrideWithValue(Duration.zero),
    ]);
    addTearDown(container.dispose);
    await container.read(syncedPreferencesProvider.future);
    container.listen(nudgeNotificationSchedulerProvider, (_, _) {});
    container.listen(activeSessionProvider, (_, _) {});
    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await pumpEventQueue();
      }
    }

    await settle();

    List<String> planned() {
      final facts = container.read(nudgeNotificationFactsProvider);
      expect(facts, isNotNull);
      return [
        for (final n in planNudgeNotifications(facts!))
          '${n.id}|${n.ritual}|${n.fireAt.toIso8601String()}|${n.payload}'
      ];
    }

    final planBefore = planned();
    final callsBefore = service.scheduleCalls.length;
    final cancelsBefore = service.cancelledIds.length;

    final ceremony = container.read(ceremonyInProgressProvider.notifier);
    ceremony.enter(RitualId.dailyPlanning);
    container.read(focusSessionPlanningProvider.notifier).goToStep(2);
    ceremony.exit(RitualId.dailyPlanning);
    await settle();

    expect(
        container
            .read(unfinishedCeremonyTriggerProvider(RitualId.dailyPlanning))
            .isFiring,
        isTrue);
    expect(planned(), planBefore);
    expect(service.scheduleCalls.length, callsBefore);
    expect(service.cancelledIds.length, cancelsBefore);
  });
}
