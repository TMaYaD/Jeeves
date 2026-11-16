import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/screens/planning/focus_session_planning_screen.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

/// The day timeline with no calendar, end to end: Today's Plan is drawn as
/// tiles on the planning completion screen, a time the user sets is fixed, and
/// Start Day writes it to the Plan entry — the only thing of the layout that is
/// stored.
///
/// Harness shape follows `start_day_lands_on_now_journey_test.dart`: the real
/// planning route over a real database, the database opened and closed outside
/// the fake-async body, and a bounded number of frames instead of
/// `pumpAndSettle`, which a live drift stream would make spin.
const _focusKey = Key('focus_route');
const _userId = 'local';

/// Drains real async and pumps a bounded number of frames.
Future<void> _pumpFrames(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ProviderContainer container;
  late GoRouter router;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    await db.todoDao.insertOutcome(
        id: 'report',
        title: 'Write the report',
        userId: _userId,
        timeEstimate: 30);
    await db.todoDao.insertOutcome(
        id: 'email', title: 'Answer email', userId: _userId, timeEstimate: 15);
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ]);
    router = GoRouter(
      initialLocation: '/focus-session-planning',
      routes: [
        GoRoute(
          path: '/focus-session-planning',
          builder: (_, _) => const FocusSessionPlanningScreen(),
        ),
        GoRoute(
            path: '/focus', builder: (_, _) => const SizedBox(key: _focusKey)),
        GoRoute(path: '/shutdown', builder: (_, _) => const SizedBox()),
      ],
    );
  });

  tearDown(() async {
    router.dispose();
    await db.close();
  });

  /// Mounts the real planning route and walks to the completion screen with
  /// both Outcomes selected.
  Future<void> openCompletionScreen(WidgetTester tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await _pumpFrames(tester);
    container.read(focusSessionPlanningProvider.notifier)
      ..selectTasks(['report', 'email'])
      ..setAvailableTime(240)
      ..goToStep(6);
    await _pumpFrames(tester);
  }

  /// Disposing the container cancels the live drift streams, which schedules a
  /// zero-duration timer; it must fire inside the test body.
  Future<void> teardownApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => pumpEventQueue());
    container.dispose();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  }

  testWidgets('with no calendar, the Plan is drawn as tiles and nothing errors',
      (tester) async {
    try {
      await openCompletionScreen(tester);

      expect(find.byKey(const Key('day_timeline')), findsOneWidget);
      expect(find.byKey(const Key('day_timeline_tile_report_1')),
          findsOneWidget);
      expect(find.byKey(const Key('day_timeline_tile_email_1')),
          findsOneWidget);
      expect(find.textContaining('Error'), findsNothing);
      expect(find.textContaining('placeholder'), findsNothing);
      expect(find.byKey(const Key('day_timeline_tray')), findsNothing);
    } finally {
      await teardownApp(tester);
    }
  });

  testWidgets(
      'a time the user sets is fixed, and Start Day writes it to the Plan entry',
      (tester) async {
    try {
      await openCompletionScreen(tester);

      await tester.tap(find.byKey(const Key('day_timeline_tile_report_1')));
      await _pumpFrames(tester);
      await tester.tap(find.byKey(const Key('set_time_later')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('set_time_confirm')));
      await tester.tap(find.byKey(const Key('set_time_confirm')));
      await _pumpFrames(tester);

      final pins =
          container.read(focusSessionPlanningProvider).pinnedStartByTaskId;
      final pinned = pins['report'];
      expect(pinned, isNotNull);
      expect(pins.containsKey('email'), isFalse);

      await tester.ensureVisible(find.text('Start Day'));
      await tester.tap(find.text('Start Day'));
      await _pumpFrames(tester, frames: 30);
      expect(find.byKey(_focusKey), findsOneWidget);

      final rows =
          (await tester.runAsync(() => db.select(db.focusSessionTasks).get()))!;
      final byTask = {for (final row in rows) row.taskId: row};
      expect(byTask['report']!.pinnedStartAt?.toUtc(), pinned!.toUtc());
      expect(byTask['email']!.pinnedStartAt, isNull);
    } finally {
      await teardownApp(tester);
    }
  });
}
