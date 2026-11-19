import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/calendar_timeline_provider.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/screens/planning/focus_session_planning_screen.dart';
import 'package:jeeves/services/calendar/calendar_types.dart';
import 'package:jeeves/services/calendar/in_memory_calendar_source.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

/// The device calendar on the day timeline, end to end, over an in-memory
/// calendar source (the adapter's test implementation): events drawn, the Plan
/// laid out around them, the calendar states, a calendar change re-flowing only
/// what is not set, the notice and Undo, and the Time check deriving the
/// day's free time. Harness shape follows `day_timeline_journey_test.dart`.
const _userId = 'local';

/// A fixed morning, so the day window (now to the 18:00 Evening Shutdown) and
/// every expected time are exact.
final _now = DateTime(2030, 3, 15, 9, 0);
DateTime _at(int hour, [int minute = 0]) => DateTime(2030, 3, 15, hour, minute);

CalendarEvent _event(String id, String title, DateTime start, DateTime end,
        {bool allDay = false}) =>
    CalendarEvent(
        id: id, title: title, start: start, end: end, isAllDay: allDay);

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
  late InMemoryCalendarSource calendar;

  Future<void> setUpApp({
    required Map<String, Object> prefs,
    List<CalendarEvent> events = const [],
    bool permissionGranted = true,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    calendar = InMemoryCalendarSource(
        events: events, permissionGranted: permissionGranted);
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
      calendarSourceProvider.overrideWithValue(calendar),
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

  Future<void> openStep(WidgetTester tester, int step) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await _pumpFrames(tester);
    container.read(focusSessionPlanningProvider.notifier)
      ..selectTasks(['report', 'email'])
      ..setAvailableTime(240)
      ..goToStep(step);
    await _pumpFrames(tester);
  }

  Future<void> calendarChanges(
      WidgetTester tester, List<CalendarEvent> events) async {
    calendar.events = events;
    await tester
        .runAsync(() => container.read(calendarTimelineProvider.notifier).refresh());
    await _pumpFrames(tester);
  }

  Future<void> teardownApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => pumpEventQueue());
    container.dispose();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  }

  /// Minutes from the top of the timeline (09:00 here) to a tile's start. The
  /// notices above the timeline shift it on screen, so a tile is measured from
  /// the timeline's own top.
  double tileMinute(WidgetTester tester, String outcomeId) =>
      tester
          .getTopLeft(find.byKey(Key('day_timeline_tile_${outcomeId}_1')))
          .dy -
      tester.getTopLeft(find.byType(DragTarget<String>)).dy;

  testWidgets('events are drawn and the Plan is laid out around them',
      (tester) async {
    await setUpApp(prefs: {kShowCalendarOnTimelineKey: true}, events: [
      _event('standup', 'Standup', _at(9), _at(10)),
      _event('holiday', 'Public holiday', _at(0), _at(23, 59), allDay: true),
    ]);
    try {
      await openStep(tester, 6);

      expect(find.byKey(const Key('day_timeline_event_standup')),
          findsOneWidget);
      expect(find.textContaining('Standup'), findsOneWidget);
      // An all-day event does not block time and is not drawn.
      expect(find.byKey(const Key('day_timeline_event_holiday')), findsNothing);
      // The first Outcome starts when the event ends; nothing overlaps it.
      expect(tileMinute(tester, 'report'), 60);
      expect(find.byKey(const Key('day_timeline_calendar_status')),
          findsNothing);
    } finally {
      await teardownApp(tester);
    }
  });

  testWidgets('a calendar change moves only what is not set, with a notice '
      'and an Undo that pins the old times', (tester) async {
    await setUpApp(prefs: {kShowCalendarOnTimelineKey: true}, events: [
      _event('standup', 'Standup', _at(9), _at(10)),
    ]);
    try {
      await openStep(tester, 6);
      final before = tileMinute(tester, 'report');

      // The standup moves to the afternoon: the morning frees up.
      await calendarChanges(tester, [
        _event('standup', 'Standup', _at(14), _at(15)),
      ]);

      expect(tileMinute(tester, 'report'), lessThan(before));
      expect(find.byKey(const Key('day_timeline_moved_notice')),
          findsOneWidget);
      expect(find.textContaining('moved 2 suggested times'), findsOneWidget);

      await tester.tap(find.byKey(const Key('day_timeline_moved_undo')));
      await _pumpFrames(tester);

      // Undo pins both entries where they were: 10:00 and 10:30.
      final pins =
          container.read(focusSessionPlanningProvider).pinnedStartByTaskId;
      expect(pins['report']!.toLocal(), _at(10));
      expect(pins['email']!.toLocal(), _at(10, 30));
      expect(find.byKey(const Key('day_timeline_moved_notice')), findsNothing);
      expect(tileMinute(tester, 'report'), before);
    } finally {
      await teardownApp(tester);
    }
  });

  testWidgets('a time the user set stays put when the calendar changes under '
      'it, and says so', (tester) async {
    await setUpApp(prefs: {kShowCalendarOnTimelineKey: true});
    try {
      await openStep(tester, 6);
      container
          .read(focusSessionPlanningProvider.notifier)
          .setPinnedStart('report', _at(12));
      await _pumpFrames(tester);
      final pinnedMinute = tileMinute(tester, 'report');
      expect(pinnedMinute, 180);

      await calendarChanges(tester, [
        _event('lunch', 'Lunch with Sam', _at(12), _at(13)),
      ]);

      expect(tileMinute(tester, 'report'), pinnedMinute);
      expect(find.byKey(const Key('day_timeline_conflict_notice')),
          findsOneWidget);

      await tester.tap(find.byKey(const Key('day_timeline_conflict_release')));
      await _pumpFrames(tester);
      expect(
          container
              .read(focusSessionPlanningProvider)
              .pinnedStartByTaskId
              .containsKey('report'),
          isFalse);
    } finally {
      await teardownApp(tester);
    }
  });

  testWidgets('when the calendar cannot be read, the timeline stays usable '
      'and Try again reads it again', (tester) async {
    await setUpApp(
      prefs: {kShowCalendarOnTimelineKey: true},
      events: [_event('standup', 'Standup', _at(9), _at(10))],
    );
    calendar.failure = CalendarReadFailure.unavailable;
    try {
      await openStep(tester, 6);

      expect(find.textContaining('could not be read'), findsOneWidget);
      expect(find.byKey(const Key('day_timeline_tile_report_1')),
          findsOneWidget);

      calendar.failure = null;
      await tester.tap(find.byKey(const Key('day_timeline_calendar_try_again')));
      await _pumpFrames(tester);
      expect(find.byKey(const Key('day_timeline_event_standup')),
          findsOneWidget);
      expect(find.byKey(const Key('day_timeline_calendar_status')),
          findsNothing);
    } finally {
      await teardownApp(tester);
    }
  });

  testWidgets('a refused permission is named, and the switch is device-local',
      (tester) async {
    await setUpApp(prefs: {}, permissionGranted: false);
    try {
      await openStep(tester, 6);
      expect(find.textContaining('No calendar connected'), findsOneWidget);

      await tester.runAsync(() =>
          container.read(calendarTimelineProvider.notifier).setSwitch(true));
      await _pumpFrames(tester);

      expect(find.textContaining('not allowed to read your calendar'),
          findsOneWidget);
      expect(find.byKey(const Key('day_timeline_tile_report_1')),
          findsOneWidget);
      // The one thing stored is the switch, in this device's preferences.
      final prefs = (await tester.runAsync(SharedPreferences.getInstance))!;
      expect(prefs.getBool(kShowCalendarOnTimelineKey), isTrue);
    } finally {
      await teardownApp(tester);
    }
  });

  testWidgets('the calendar is re-read every five minutes while the timeline '
      'is visible', (tester) async {
    await setUpApp(prefs: {kShowCalendarOnTimelineKey: true});
    try {
      await openStep(tester, 6);
      final readsBefore = calendar.readCount;
      await tester.pump(const Duration(minutes: 5));
      await _pumpFrames(tester);
      expect(calendar.readCount, greaterThan(readsBefore));
    } finally {
      await teardownApp(tester);
    }
  });

  testWidgets('the Time check lists the events and derives the free time '
      'to the Evening Shutdown time', (tester) async {
    await setUpApp(prefs: {kShowCalendarOnTimelineKey: true}, events: [
      _event('standup', 'Standup', _at(9), _at(10)),
      _event('lunch', 'Lunch', _at(12), _at(13)),
    ]);
    try {
      await openStep(tester, 4);

      expect(find.textContaining('placeholder'), findsNothing);
      expect(find.textContaining('Standup'), findsOneWidget);
      expect(find.textContaining('Lunch'), findsOneWidget);
      // 09:00 to 18:00 is 540 minutes, less two hours of events.
      expect(find.text('7h 0m available today'), findsOneWidget);
      expect(container.read(focusSessionPlanningProvider).availableMinutes,
          420);
      expect(find.text('How much time do you have today?'), findsNothing);
    } finally {
      await teardownApp(tester);
    }
  });

  testWidgets('with no calendar the Time check still asks for the time',
      (tester) async {
    await setUpApp(prefs: {});
    try {
      await openStep(tester, 4);
      expect(find.text('How much time do you have today?'), findsOneWidget);
      expect(find.textContaining('placeholder'), findsNothing);
    } finally {
      await teardownApp(tester);
    }
  });
}
