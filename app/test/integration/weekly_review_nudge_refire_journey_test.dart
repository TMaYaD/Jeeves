import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/nudge_provider.dart';
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
  late DateTime now;
  late DateTime firstDue;
  late DateTime nextDue;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    // Dismiss uses the real wall clock. Put the first edge just before it,
    // and the next edge at midday so midnight cannot stand in for its timer.
    final today = DateTime.now();
    firstDue = DateTime(today.year, today.month, today.day - 1, 12);
    now = today;
    nextDue = firstDue.add(const Duration(days: 7));
    c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => now),
      notificationServiceProvider
          .overrideWithValue(StubPeriodicReviewNotificationService()),
    ]);

    await db.captureDao.insertCapture(CapturesCompanion(
      id: const Value('inbox'),
      title: const Value('Review this capture'),
      userId: const Value('local'),
      createdAt: Value(firstDue),
      updatedAt: Value(firstDue),
    ));
    await c.read(syncedPreferencesProvider.future);
    await c.read(syncedPreferencesProvider.notifier).set(
          'periodic_review_last_completed_at',
          firstDue.subtract(const Duration(days: 7)).toIso8601String(),
        );
  });

  tearDown(() async {
    c.dispose();
    await db.close();
  });

  testWidgets('dismissed Weekly Review banner returns at the next cadence edge',
      (tester) async {
    try {
      appRouter.go('/inbox');
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp.router(routerConfig: appRouter),
      ));
      await _flush(tester);
      final banner = find.byKey(const Key('periodic_review_banner_visible'));
      expect(banner, findsOneWidget);

      await tester.tap(find.byKey(const Key('periodic_review_banner_dismiss')));
      await _flush(tester);
      expect(banner, findsNothing);
      final dismissedAt =
          c.read(nudgeStateProvider(RitualId.weeklyReview)).dismissedAt;
      expect(dismissedAt, isNotNull);

      // Keep the real boundary provider live. No provider invalidation or
      // clock override replacement: only elapsed time may restore the banner.
      final beforeRefire = nextDue.subtract(const Duration(seconds: 1));
      final elapsed = beforeRefire.difference(now);
      now = beforeRefire;
      await tester.pump(elapsed);
      await _flush(tester);
      expect(banner, findsNothing);

      now = nextDue;
      await tester.pump(const Duration(seconds: 1));
      await _flush(tester);
      expect(banner, findsOneWidget);
      expect(c.read(nudgeStateProvider(RitualId.weeklyReview)).dismissedAt,
          dismissedAt, reason: 'refiring must not clear the persisted dismissal');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
