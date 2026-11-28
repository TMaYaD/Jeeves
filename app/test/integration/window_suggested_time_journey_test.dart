/// The suggested time of an Outcome with a time window (#1097), end to end:
/// Daily Planning's completion step lays the picked Outcomes on the day
/// timeline, and an Outcome with a time window — a named one or the one-time
/// kind — gets a time inside the window, not the first free minute of the day.
/// Harness shape follows `calendar_timeline_journey_test.dart`.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/time_context.dart';
import 'package:jeeves/models/time_window_hours.dart';
import 'package:jeeves/providers/calendar_timeline_provider.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/screens/planning/focus_session_planning_screen.dart';
import 'package:jeeves/services/calendar/in_memory_calendar_source.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

const _userId = 'local';

/// Monday, 23 November 2026, 09:00: the top of the timeline.
final _now = DateTime(2026, 11, 23, 9, 0);

/// Minutes from the top of the timeline (09:00) at which the window opens and
/// closes (11:00 and 20:00).
const _windowOpensMinute = 2 * 60;
const _windowClosesMinute = 11 * 60;

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

  Future<void> insert(String id, int minutes) async {
    await db.todoDao.insertOutcome(
        id: id, title: id, userId: _userId, timeEstimate: minutes);
    await seedCurrentAction(db,
        outcomeId: id, text: 'work on $id', userId: _userId);
  }

  Future<void> attachNamedWindow(String id) async {
    final windowId = await db.timeWindowDao.createTimeWindow(
      name: 'Store hours',
      hours: {
        for (var day = 1; day <= 7; day++)
          day: (startMinute: 11 * 60, endMinute: 20 * 60),
      },
      userId: _userId,
    );
    final actionId = (await db.actionDao.getCurrentAction(id))!.id;
    await db.actionDao.setTimeWindow(actionId, windowId!);
  }

  Future<void> attachOneTimeWindow(String id) async {
    final actionId = (await db.actionDao.getCurrentAction(id))!.id;
    await db.actionDao.setTimeContext(
        actionId,
        TimeContext.create(
            days: {1, 2, 3, 4, 5, 6, 7},
            startMinute: 11 * 60,
            endMinute: 20 * 60));
  }

  Future<void> setUpApp() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
      calendarSourceProvider.overrideWithValue(InMemoryCalendarSource()),
      clockProvider.overrideWithValue(() => _now),
    ]);
    router = GoRouter(
      initialLocation: '/focus-session-planning',
      routes: [
        GoRoute(
          path: '/focus-session-planning',
          builder: (_, _) => const FocusSessionPlanningScreen(),
        ),
        GoRoute(path: '/focus', builder: (_, _) => const SizedBox()),
        GoRoute(path: '/shutdown', builder: (_, _) => const SizedBox()),
      ],
    );
  }

  tearDown(() async {
    router.dispose();
    await db.close();
  });

  /// Picks [ids], in that order, with 09:00 to 20:00 available, and opens the
  /// day timeline.
  Future<void> pickAndOpenTimeline(WidgetTester tester, List<String> ids) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await _pumpFrames(tester);
    container.read(focusSessionPlanningProvider.notifier)
      ..selectTasks(ids)
      ..setAvailableTime(11 * 60)
      ..goToStep(6);
    await _pumpFrames(tester);
  }

  Future<void> teardownApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => pumpEventQueue());
    container.dispose();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  }

  /// Minutes from the top of the timeline to a tile's start.
  double tileMinute(WidgetTester tester, String outcomeId) =>
      tester
          .getTopLeft(find.byKey(Key('day_timeline_tile_${outcomeId}_1')))
          .dy -
      tester.getTopLeft(find.byType(DragTarget<String>)).dy;

  testWidgets('an Outcome on a named window, picked into an empty plan, '
      'is suggested inside the window', (tester) async {
    await setUpApp();
    try {
      await insert('store', 60);
      await attachNamedWindow('store');
      await pickAndOpenTimeline(tester, ['store']);

      final start = tileMinute(tester, 'store');
      expect(start, greaterThanOrEqualTo(_windowOpensMinute));
      expect(start + 60, lessThanOrEqualTo(_windowClosesMinute));
    } finally {
      await teardownApp(tester);
    }
  });

  testWidgets('with entries already in the plan, a window Outcome still lands '
      'inside its window and does not overlap them', (tester) async {
    await setUpApp();
    try {
      await insert('report', 150);
      await insert('store', 60);
      await insert('oneoff', 60);
      await attachNamedWindow('store');
      await attachOneTimeWindow('oneoff');
      await pickAndOpenTimeline(tester, ['report', 'store', 'oneoff']);

      expect(tileMinute(tester, 'report'), 0);
      for (final id in ['store', 'oneoff']) {
        final start = tileMinute(tester, id);
        expect(start, greaterThanOrEqualTo(_windowOpensMinute), reason: id);
        expect(start, greaterThanOrEqualTo(150), reason: id);
        expect(start + 60, lessThanOrEqualTo(_windowClosesMinute), reason: id);
      }
      expect(
          (tileMinute(tester, 'store') - tileMinute(tester, 'oneoff')).abs(),
          greaterThanOrEqualTo(60));
    } finally {
      await teardownApp(tester);
    }
  });

  testWidgets('an Outcome with no window is placed where it was before',
      (tester) async {
    await setUpApp();
    try {
      await insert('store', 60);
      await insert('plain', 30);
      await attachNamedWindow('store');
      await pickAndOpenTimeline(tester, ['store', 'plain']);

      expect(tileMinute(tester, 'plain'), 0);
    } finally {
      await teardownApp(tester);
    }
  });
}
