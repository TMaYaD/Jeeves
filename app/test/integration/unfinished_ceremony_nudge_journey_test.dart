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
import 'package:jeeves/providers/focus_session_planning_provider.dart';
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

  final banner = find.byKey(const Key('daily_planning_banner_visible'));
  final unfinishedLine = find.text('Daily Planning, sir. Unfinished.');

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

  Future<void> goTo(WidgetTester tester, String location) async {
    appRouter.go(location);
    await _flush(tester);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 100));
    await _flush(tester);
  }

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
}
