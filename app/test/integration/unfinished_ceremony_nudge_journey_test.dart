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
  // When set, replaces the default clock: lets a journey pin "before the
  // anchor" or jump to the next period.
  DateTime Function()? clockOverride;

  final banner = find.byKey(const Key('planning_banner_visible'));
  // Continue wording is shown exactly while the Unfinished Trigger fires; assert
  // that state rather than copy.
  bool planningUnfinished() => c
      .read(unfinishedCeremonyTriggerProvider(RitualId.dailyPlanning))
      .isFiring;
  bool shutdownUnfinished() => c
      .read(unfinishedCeremonyTriggerProvider(RitualId.eveningShutdown))
      .isFiring;
  final shutdownBanner = find.byKey(const Key('shutdown_banner_visible'));
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
    clockOverride = null;
    c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      // Fixed at noon: before the shutdown anchor whatever the wall clock is,
      // and a swipe stamps this same clock.
      clockProvider.overrideWithValue(() => clockOverride?.call() ?? noon),
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
      expect(planningUnfinished(), isFalse, reason: 'start wording first');

      await tester.drag(banner, const Offset(-300, 0));
      await _flush(tester);
      expect(banner, findsNothing);

      // The swipe was stamped at noon. Visibility needs the dismissal strictly
      // before the firing edge, so the leave below must happen later.
      clockOverride = () => noon.add(const Duration(hours: 1));

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
      expect(planningUnfinished(), isTrue);
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
      expect(planningUnfinished(), isTrue);

      await goTo(tester, '/focus');
      expect(banner, findsNothing, reason: 'the Now screen carries no Banner');
      expect(emptyState, findsOneWidget);
      expect(planningUnfinished(), isTrue);

      await tester.tap(emptyStateButton);
      await _flush(tester);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(FocusSessionPlanningScreen), findsOneWidget);
    } finally {
      await tearDownApp(tester);
    }
  });

  testWidgets(
      'finishing Daily Planning clears the unfinished Nudge; the next period '
      'starts in start wording', (tester) async {
    try {
      await pumpApp(tester);
      await startAndLeavePlanning(tester);
      expect(planningUnfinished(), isTrue);

      // The real completion path: startDay() opens the session.
      await tester.runAsync(
          () => c.read(focusSessionPlanningProvider.notifier).startDay());
      await _flush(tester);
      expect(planningUnfinished(), isFalse);

      // Close the day through the Ceremony, then move to the next morning.
      await tester.runAsync(
          () => c.read(eveningShutdownProvider.notifier).closeDay());
      await _flush(tester);
      expect(planningUnfinished(), isFalse);

      final nextDayNoon = noon.add(const Duration(days: 1));
      clockOverride = () => nextDayNoon;
      await tester.pump(const Duration(days: 1));
      await _flush(tester);
      expect(banner, findsOneWidget,
          reason: 'the next period is due again');
      expect(planningUnfinished(), isFalse,
          reason: 'and in start wording, not continue');
    } finally {
      await tearDownApp(tester);
    }
  });

  testWidgets(
      'Evening Shutdown left unfinished before its anchor shows the continue '
      'Nudge; a session closed without the Ceremony voids it, a new one fires '
      'again, and Close Day clears it', (tester) async {
    final morning = DateTime(noon.year, noon.month, noon.day, 10);
    clockOverride = () => morning;
    late String firstId;
    await tester.runAsync(() async {
      firstId =
          await db.focusSessionDao.openSession(userId: 'local', taskIds: []);
    });
    try {
      await pumpApp(tester);
      expect(shutdownBanner, findsNothing, reason: 'before the anchor');

      // The screen's own lifecycle marks the start; nothing is called by hand.
      await goTo(tester, '/shutdown');
      await goTo(tester, '/inbox');
      expect(shutdownBanner, findsOneWidget);
      expect(shutdownUnfinished(), isTrue);

      // End Session without the Ceremony voids the fact.
      await tester.runAsync(
          () => db.focusSessionDao.closeSession(sessionId: firstId));
      await _flush(tester);
      expect(shutdownBanner, findsNothing);

      // A later session, started and left, fires again against its own id.
      await tester.runAsync(() =>
          db.focusSessionDao.openSession(userId: 'local', taskIds: []));
      await _flush(tester);
      expect(shutdownBanner, findsNothing);
      await goTo(tester, '/shutdown');
      await goTo(tester, '/inbox');
      expect(shutdownUnfinished(), isTrue);

      // Close Day, the real completion path, clears it.
      await tester.runAsync(
          () => c.read(eveningShutdownProvider.notifier).closeDay());
      await _flush(tester);
      expect(shutdownBanner, findsNothing);
    } finally {
      await tearDownApp(tester);
    }
  });

  testWidgets(
      'a due Weekly Review outranks an unfinished Daily Planning until swiped',
      (tester) async {
    await tester.runAsync(() async {
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
    });
    try {
      await pumpApp(tester);
      await startAndLeavePlanning(tester);
      expect(reviewBanner, findsOneWidget);
      expect(banner, findsNothing);

      await tester.drag(reviewBanner, const Offset(-300, 0));
      await _flush(tester);
      expect(banner, findsOneWidget);
      expect(planningUnfinished(), isTrue);
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
