// Journey for Inbox too full and the Now screen: with more than 50 Captures the
// untinted Banner sits ahead of a due Weekly Review and cannot be swiped away;
// its button opens Inbox clarification one Capture at a time, oldest first;
// at 50 it is gone and the Weekly Review shows. The Now screen carries the
// nudge in its empty state, never a Banner.
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/router.dart';
import 'package:jeeves/screens/inbox/inbox_clarify_screen.dart';
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

  final tooFull = find.byKey(const Key('inbox_too_full_banner_visible'));
  final reviewBanner =
      find.byKey(const Key('periodic_review_banner_visible'));

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

  /// 51 Captures created a day apart, oldest `c00`, so the review is due too.
  Future<void> seedFiftyOneCaptures() async {
    for (var i = 0; i < 51; i++) {
      await insertCapture(
          'c${i.toString().padLeft(2, '0')}',
          startedAt.subtract(Duration(days: 60 - i)));
    }
  }

  testWidgets(
      '51 Captures: the Banner leads the Weekly Review, a swipe does nothing, '
      'At once clarifies oldest first, and at 50 the Weekly Review shows',
      (tester) async {
    await seedFiftyOneCaptures();
    try {
      await pumpApp(tester);
      expect(tooFull, findsOneWidget);
      expect(reviewBanner, findsNothing);
      expect(find.byIcon(Icons.close), findsNothing);

      await tester.drag(tooFull, const Offset(-300, 0));
      await _flush(tester);
      expect(tooFull, findsOneWidget, reason: 'a swipe does nothing');

      appRouter.go('/next');
      await _flush(tester);
      expect(tooFull, findsOneWidget);

      await tester.tap(find.text('At once  →'));
      await _flush(tester);
      expect(find.byType(InboxClarifyScreen), findsOneWidget);
      expect(find.text('Capture c00'), findsOneWidget,
          reason: 'the oldest Capture comes first');

      await tester.tap(find.text('Next Action'));
      await _flush(tester);
      await tester.tap(find.text('Save'));
      await _flush(tester);
      expect(find.text('Capture c01'), findsOneWidget,
          reason: 'a verdict moves on to the next oldest');

      // The Inbox is now at 50: leave the sequence; Inbox too full is gone and
      // the Weekly Review takes the slot.
      await tester.tap(find.byKey(const Key('app_title_bar_leading')));
      await _flush(tester);
      expect(find.byType(InboxClarifyScreen), findsNothing);
      expect(tooFull, findsNothing);
      expect(reviewBanner, findsOneWidget);
    } finally {
      await tearDownApp(tester);
    }
  });

  testWidgets(
      'the Now screen shows no Banner: the empty state carries the nudge and '
      'the sun action opens Daily Planning', (tester) async {
    await seedFiftyOneCaptures();
    try {
      await pumpApp(tester);
      appRouter.go('/focus');
      await _flush(tester);
      expect(tooFull, findsNothing);
      expect(reviewBanner, findsNothing);
      expect(find.byKey(const Key('nudge_empty_state')), findsOneWidget);
      expect(find.byKey(const Key('focus_plan_the_day')), findsOneWidget);

      await tester.tap(find.byKey(const Key('focus_plan_the_day')));
      await _flush(tester);
      expect(
          appRouter.routeInformationProvider.value.uri.path,
          '/focus-session-planning');
    } finally {
      await tearDownApp(tester);
    }
  });

  testWidgets('with no head, the Now screen keeps Plan the Day',
      (tester) async {
    try {
      await pumpApp(tester);
      appRouter.go('/focus');
      await _flush(tester);
      expect(find.byKey(const Key('nudge_empty_state')), findsNothing);
      expect(find.text('Plan the Day'), findsOneWidget);
    } finally {
      await tearDownApp(tester);
    }
  });
}
