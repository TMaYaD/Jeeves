// Journeys for the Weekly Review Nudge: it returns daily while the review is
// due, comes back at once in continue wording after an unfinished session, is
// cleared by a finished session (a short one included) for seven days, and is
// closed with a horizontal swipe, never a ✕.
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/ceremony_in_progress_provider.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/nudge_provider.dart';
import 'package:jeeves/providers/periodic_review_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/router.dart';
import 'package:jeeves/screens/periodic_review/periodic_review_screen.dart';
import 'package:jeeves/screens/periodic_review/steps/waiting_for_step.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/periodic_review_test_helpers.dart';
import '../test_helpers.dart';

// The banner pulses indefinitely; drain real database work without waiting
// for animations to settle, or advancing the boundary timer's fake clock.
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
  late DateTime startedAt;
  DateTime Function()? advancingClock;

  final banner = find.byKey(const Key('periodic_review_banner_visible'));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    // Noon of the real local day: the journeys advance hours and days, so a
    // start near midnight would cross a day boundary the assertions don't expect.
    final today = DateTime.now();
    startedAt = DateTime(today.year, today.month, today.day, 12);
    advancingClock = null;
    c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => advancingClock?.call() ?? startedAt),
      notificationServiceProvider
          .overrideWithValue(StubPeriodicReviewNotificationService()),
    ]);
    await c.read(syncedPreferencesProvider.future);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> insertCapture(String id, DateTime createdAt) =>
      db.captureDao.insertCapture(CapturesCompanion(
        id: Value(id),
        title: Value('Capture $id'),
        userId: const Value('local'),
        createdAt: Value(createdAt),
        updatedAt: Value(createdAt),
      ));

  Future<void> setLastCompleted(DateTime at) => c
      .read(syncedPreferencesProvider.notifier)
      .set('periodic_review_last_completed_at', at.toUtc().toIso8601String());

  /// Mounts the app on the Inbox with a clock that follows the test's fake
  /// time, so only elapsed time (never a provider override) moves the Nudge.
  Future<void> pumpApp(WidgetTester tester) async {
    final clockStart = tester.binding.clock.now();
    final initialNow = startedAt;
    advancingClock =
        () => initialNow.add(tester.binding.clock.now().difference(clockStart));
    appRouter.go('/inbox');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp.router(routerConfig: appRouter),
    ));
    await _flush(tester);
  }

  Future<void> tearDownApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    // Flutter checks pending timers before tearDown. Cancel the boundary
    // timer now, but let Drift subscription cleanup finish in real async.
    await tester.runAsync(() async {
      c.dispose();
      await pumpEventQueue();
    });
  }

  Future<void> swipeAway(WidgetTester tester) async {
    await tester.drag(banner, const Offset(-300, 0));
    await _flush(tester);
  }

  testWidgets('a due review shows the Banner; a swipe hides it until tomorrow',
      (tester) async {
    await insertCapture('inbox', startedAt.subtract(const Duration(days: 20)));
    await setLastCompleted(startedAt.subtract(const Duration(days: 10)));
    try {
      await pumpApp(tester);
      expect(banner, findsOneWidget);
      expect(find.textContaining(RegExp(r'^(The Weekly Review, sir\. Three days late\.|Three days past the review, sir\.)$')),
          findsOneWidget);
      expect(find.byIcon(Icons.close), findsNothing,
          reason: 'no Banner carries a ✕');

      await swipeAway(tester);
      expect(banner, findsNothing);
      final dismissedAt =
          c.read(nudgeStateProvider(RitualId.weeklyReview)).dismissedAt;
      expect(dismissedAt, isNotNull);

      // Later the same day it stays hidden.
      await tester.pump(const Duration(hours: 1));
      await _flush(tester);
      expect(banner, findsNothing);

      // Tomorrow it is back, and the swipe's record is untouched.
      await tester.pump(const Duration(days: 1));
      await _flush(tester);
      expect(banner, findsOneWidget);
      expect(find.textContaining(RegExp(r'^(The Weekly Review, sir\. Four days late\.|Four days past the review, sir\.)$')),
          findsOneWidget);
      expect(c.read(nudgeStateProvider(RitualId.weeklyReview)).dismissedAt,
          dismissedAt);
    } finally {
      await tearDownApp(tester);
    }
  });

  testWidgets(
      'leaving a started 15-minute session on step 2 brings the Banner back at '
      'once, in continue wording, even after a swipe earlier that day; the '
      'Banner reopens the review at that step', (tester) async {
    await insertCapture('inbox', startedAt.subtract(const Duration(days: 20)));
    // Ten Next Outcomes make a 15-minute session a partial one.
    for (var index = 0; index < 10; index++) {
      await db.into(db.todos).insert(TodosCompanion(
            id: Value('outcome-$index'),
            title: Value('Outcome $index'),
            userId: const Value('local'),
            intent: const Value('next'),
            createdAt: Value(startedAt.subtract(const Duration(days: 30))),
            updatedAt: Value(startedAt.subtract(const Duration(days: 30))),
          ));
    }
    await setLastCompleted(startedAt.subtract(const Duration(days: 10)));

    Future<void> tapKey(Key key) async {
      // Step changes slide in; wait for the previous one before tapping.
      await tester.pump(const Duration(milliseconds: 600));
      final finder = find.byKey(key);
      await tester.ensureVisible(finder);
      await tester.runAsync(() async {
        await tester.tap(finder);
        await pumpEventQueue();
      });
      await _flush(tester);
    }

    try {
      await pumpApp(tester);
      await swipeAway(tester);
      expect(banner, findsNothing);

      // Open the Weekly Review by route (the Banner is swiped away), pick the
      // 15-minute session and move on to step 2.
      await tester.pump(const Duration(minutes: 5));
      appRouter.go('/periodic-review');
      await _flush(tester);
      // Let the route transition finish (the Banner's pulse rules out
      // pumpAndSettle); the footer is off-screen until then.
      await tester.pump(const Duration(milliseconds: 600));
      expect(banner, findsNothing, reason: 'hidden while the Ceremony is open');
      await tester.ensureVisible(find.text('15 min'));
      await tester.runAsync(() async {
        await tester.tap(find.text('15 min'));
        await pumpEventQueue();
      });
      await _flush(tester);
      await tapKey(const Key('periodic_review_next_step'));
      expect(c.read(periodicReviewProvider).sessionStarted, isTrue);
      expect(c.read(periodicReviewProvider).currentStep,
          PeriodicReviewNotifier.kStepInbox);
      // Skip walks the Inbox cursor; Next step crosses into step 2.
      for (var taps = 0;
          c.read(periodicReviewProvider).currentStep <
                  PeriodicReviewNotifier.kStepWaitingFor &&
              taps < 6;
          taps++) {
        await tester.pump(const Duration(milliseconds: 600));
        await tapKey(find.byKey(const Key('periodic_review_skip')).evaluate().isNotEmpty
            ? const Key('periodic_review_skip')
            : const Key('periodic_review_next_step'));
      }
      const stepLeftAt = PeriodicReviewNotifier.kStepWaitingFor;
      expect(c.read(periodicReviewProvider).currentStep, stepLeftAt);

      // Leave without Done.
      appRouter.go('/inbox');
      await _flush(tester);
      // The old route is removed (and the screen disposed) a frame after its
      // exit transition ends.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 100));
      await _flush(tester);
      expect(banner, findsOneWidget);
      expect(
          find.textContaining(RegExp(
              r'^(The Weekly Review, sir\. Unfinished\.|We left the review half done, sir\.|Half a review, sir\.)$')),
          findsOneWidget);
      expect(find.textContaining(RegExp(r'^(Push on|Carry on|On we go)')),
          findsOneWidget);

      // Tapping the Banner reopens the review at the step it left.
      await tester.runAsync(() async {
        await tester.tap(banner);
        await pumpEventQueue();
      });
      await _flush(tester);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(PeriodicReviewScreen), findsOneWidget);
      expect(c.read(periodicReviewProvider).currentStep, stepLeftAt);
      expect(banner, findsNothing);
      expect(find.byType(WaitingForStep), findsOneWidget,
          reason: 'the reopened review renders the Waiting For body');

      // A second unfinished exit brings the Banner back too, even after the
      // first one was swiped away.
      appRouter.go('/inbox');
      await _flush(tester);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 100));
      await _flush(tester);
      expect(banner, findsOneWidget);
      await swipeAway(tester);
      expect(banner, findsNothing);

      await tester.pump(const Duration(minutes: 5));
      appRouter.go('/periodic-review');
      await _flush(tester);
      await tester.pump(const Duration(milliseconds: 600));
      expect(banner, findsNothing);
      appRouter.go('/inbox');
      await _flush(tester);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 100));
      await _flush(tester);
      expect(banner, findsOneWidget,
          reason: 'every unfinished exit returns the Banner at once');
    } finally {
      await tearDownApp(tester);
    }
  });

  testWidgets(
      'a short session finished with Done clears the Banner; it returns seven '
      'days later', (tester) async {
    // More Captures than a 15-minute session holds (7 items), so the session is
    // genuinely partial.
    for (var i = 0; i < 8; i++) {
      await insertCapture(
          'inbox-$i', startedAt.subtract(const Duration(days: 20)));
    }
    await setLastCompleted(startedAt.subtract(const Duration(days: 10)));
    // Start a 15-minute session, leave it, then finish it with Done, before
    // the app mounts: the review was due, and Done stamps the last review.
    final ceremony = c.read(ceremonyInProgressProvider.notifier);
    final review = c.read(periodicReviewProvider.notifier);
    await tester.runAsync(() async {
      ceremony.enter(RitualId.weeklyReview);
      await review.startSession(budgetMinutes: 15);
      expect(c.read(periodicReviewProvider).isFinalSession, isFalse,
          reason: 'eight Captures exceed a 15-minute session');
      ceremony.exit(RitualId.weeklyReview);
      await review.completeSession();
    });
    try {
      await pumpApp(tester);
      expect(banner, findsNothing);

      for (var day = 1; day <= 6; day++) {
        await tester.pump(const Duration(days: 1));
        await _flush(tester);
        expect(banner, findsNothing, reason: 'day $day after the session');
      }
      await tester.pump(const Duration(days: 1, minutes: 1));
      await _flush(tester);
      expect(banner, findsOneWidget);
    } finally {
      await tearDownApp(tester);
    }
  });

  testWidgets(
      'a swipe hides the Daily Planning Banner until its next firing, never '
      'showing a ✕', (tester) async {
    final today = DateTime(startedAt.year, startedAt.month, startedAt.day);
    startedAt = today.add(const Duration(hours: 10));
    await insertCapture('inbox', startedAt.subtract(const Duration(hours: 1)));
    final planningBanner = find.byKey(const Key('planning_banner_visible'));
    try {
      await pumpApp(tester);
      expect(planningBanner, findsOneWidget);
      expect(find.byIcon(Icons.close), findsNothing);

      await tester.drag(planningBanner, const Offset(-300, 0));
      await _flush(tester);
      expect(planningBanner, findsNothing);
      expect(c.read(nudgeStateProvider(RitualId.dailyPlanning)).dismissedAt,
          isNotNull);

      // Still hidden later the same day.
      await tester.pump(const Duration(hours: 2));
      await _flush(tester);
      expect(planningBanner, findsNothing);

      // The evening Shutdown time opens the next planning period: a new firing
      // (12:00 + 6h05 = 18:05).
      await tester.pump(const Duration(hours: 6, minutes: 5));
      await _flush(tester);
      expect(planningBanner, findsOneWidget);
    } finally {
      await tearDownApp(tester);
    }
  });

  testWidgets(
      'a new user is first nudged seven days after their first Capture',
      (tester) async {
    await insertCapture('first', startedAt.subtract(const Duration(days: 6)));
    try {
      await pumpApp(tester);
      expect(banner, findsNothing);

      await tester.pump(const Duration(days: 1, minutes: 1));
      await _flush(tester);
      expect(banner, findsOneWidget);
      expect(
          find.textContaining(RegExp(
              r'^(The Weekly Review is due, sir\.|Review day, sir\.|The week wants its review, sir\.)$')),
          findsOneWidget);
    } finally {
      await tearDownApp(tester);
    }
  });
}
