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
    startedAt = DateTime.now();
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
      expect(find.text('The Weekly Review, sir. Three days late.'),
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
      expect(find.text('The Weekly Review, sir. Four days late.'),
          findsOneWidget);
      expect(c.read(nudgeStateProvider(RitualId.weeklyReview)).dismissedAt,
          dismissedAt);
    } finally {
      await tearDownApp(tester);
    }
  });

  testWidgets(
      'leaving a started session brings the Banner back at once, in continue '
      'wording, even after a swipe earlier that day', (tester) async {
    await insertCapture('inbox', startedAt.subtract(const Duration(days: 20)));
    await setLastCompleted(startedAt.subtract(const Duration(days: 10)));
    try {
      await pumpApp(tester);
      await swipeAway(tester);
      expect(banner, findsNothing);

      await tester.pump(const Duration(minutes: 5));
      final ceremony = c.read(ceremonyInProgressProvider.notifier);
      final review = c.read(periodicReviewProvider.notifier);
      // What the Weekly Review screen does on entry, then the user starts a
      // 15-minute session and moves on.
      ceremony.enter(RitualId.weeklyReview);
      await tester.runAsync(() => review.startSession(budgetMinutes: 15));
      await _flush(tester);
      final stepLeftAt = c.read(periodicReviewProvider).currentStep;
      expect(c.read(periodicReviewProvider).sessionStarted, isTrue);
      expect(banner, findsNothing, reason: 'hidden while the Ceremony is open');

      // Leave without Done (the screen's dispose).
      ceremony.exit(RitualId.weeklyReview);
      await _flush(tester);
      expect(banner, findsOneWidget);
      expect(find.text('The Weekly Review, sir. Unfinished.'), findsOneWidget);
      expect(find.text('Push on  →'), findsOneWidget);

      // Reopening resumes at the step it left: nothing reset the notifier.
      expect(c.read(periodicReviewProvider).currentStep, stepLeftAt);
    } finally {
      await tearDownApp(tester);
    }
  });

  testWidgets(
      'finishing a short session clears the Banner; it returns seven days later',
      (tester) async {
    await insertCapture('inbox', startedAt.subtract(const Duration(days: 20)));
    await setLastCompleted(startedAt.subtract(const Duration(days: 10)));
    try {
      await pumpApp(tester);
      expect(banner, findsOneWidget);

      final ceremony = c.read(ceremonyInProgressProvider.notifier);
      final review = c.read(periodicReviewProvider.notifier);
      ceremony.enter(RitualId.weeklyReview);
      await tester.runAsync(() => review.startSession(budgetMinutes: 15));
      await _flush(tester);
      ceremony.exit(RitualId.weeklyReview);
      await _flush(tester);
      expect(find.text('The Weekly Review, sir. Unfinished.'), findsOneWidget);

      // Done on the summary of a session.
      await tester.runAsync(() => review.completeSession());
      await _flush(tester);
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
      'a new user is first nudged seven days after their first Capture',
      (tester) async {
    await insertCapture('first', startedAt.subtract(const Duration(days: 6)));
    try {
      await pumpApp(tester);
      expect(banner, findsNothing);

      await tester.pump(const Duration(days: 1, minutes: 1));
      await _flush(tester);
      expect(banner, findsOneWidget);
      expect(find.text('The Weekly Review is due, sir.'), findsOneWidget);
    } finally {
      await tearDownApp(tester);
    }
  });
}
