/// The planned day journey (#1077), over a real in-memory store.
///
/// Daily Planning's Up Next shows the Outcomes whose time opens in the day
/// being planned — now to today's Evening Shutdown time — and not only the
/// ones whose time is open right now. Provider plus real DB, no widgets: a live
/// Drift `watch()` hangs under widget-test fake time (docs/TESTING.md).
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/action_place_and_time_window.dart';
import 'package:jeeves/models/planned_day.dart';
import 'package:jeeves/models/time_context.dart';
import 'package:jeeves/models/time_window_hours.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/shutdown_settings_provider.dart';
import 'package:jeeves/providers/time_context_provider.dart';
import 'package:jeeves/providers/time_window_provider.dart';
import 'package:jeeves/services/notification_service.dart';

import '../test_helpers.dart';

const _userId = 'local';

/// Every ISO weekday: Monday is 1.
const _everyDay = {1, 2, 3, 4, 5, 6, 7};

/// Monday, 23 November 2026, 09:00. The Evening Shutdown time is the default
/// 18:00, so the planned day runs from 09:00 to 18:00.
final _mondayMorning = DateTime(2026, 11, 23, 9);

/// Tuesday, 24 November 2026, 01:00 — the small hours of the planned day.
final _tuesdaySmallHours = DateTime(2026, 11, 24, 1);

/// Every day of the week, 11:00 to 20:00.
final _everyDayElevenToTwenty = <int, DayHours>{
  for (var day = 1; day <= 7; day++)
    day: (startMinute: 11 * 60, endMinute: 20 * 60),
};

/// Every day of the week, 08:00 to 20:00.
final _everyDayEightToTwenty = <int, DayHours>{
  for (var day = 1; day <= 7; day++)
    day: (startMinute: 8 * 60, endMinute: 20 * 60),
};

/// Wednesday only, the whole day.
final _wednesdayOnly = <int, DayHours>{
  3: (startMinute: 0, endMinute: 24 * 60),
};

/// Monday only, 22:00 to 02:00 — a window that runs past midnight.
final _mondayNight = <int, DayHours>{
  1: (startMinute: 22 * 60, endMinute: 2 * 60),
};

Future<void> _insertOutcome(GtdDatabase db, String id) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Outcome $id'),
        intent: const Value('next'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  await seedCurrentAction(db,
      outcomeId: id, text: 'work on $id', userId: _userId);
}

/// Attaches [timeContext] to the current Action of [outcomeId].
Future<void> _setTime(GtdDatabase db, String outcomeId, TimeContext? tc) async {
  final actionId = (await db.actionDao.getCurrentAction(outcomeId))!.id;
  await db.actionDao.setTimeContext(actionId, tc);
}

/// Creates a named time window and returns its id.
Future<String> _createWindow(
  GtdDatabase db,
  String name,
  Map<int, DayHours> hours,
) async {
  final id = await db.timeWindowDao.createTimeWindow(
    name: name,
    hours: hours,
    userId: _userId,
  );
  expect(id, isNotNull);
  return id!;
}

/// Attaches the named time window [windowId] to the current Action of
/// [outcomeId].
Future<void> _setWindow(
  GtdDatabase db,
  String outcomeId,
  String windowId,
) async {
  final actionId = (await db.actionDao.getCurrentAction(outcomeId))!.id;
  await db.actionDao.setTimeWindow(actionId, windowId);
}

/// The Outcomes of the scenario: one whose time opens later today, one that
/// opens only on a Wednesday, one that opens after the Evening Shutdown time,
/// one that closed earlier today, and one with no time at all.
Future<void> _seedScenario(GtdDatabase db) async {
  for (final id in ['later', 'wednesday', 'late', 'closed', 'plain']) {
    await _insertOutcome(db, id);
  }
  await _setTime(
    db,
    'later',
    TimeContext.create(
        days: _everyDay, startMinute: 11 * 60, endMinute: 20 * 60),
  );
  await _setTime(db, 'wednesday', TimeContext.create(days: {3}));
  await _setTime(
    db,
    'late',
    TimeContext.create(
        days: _everyDay, startMinute: 19 * 60, endMinute: 21 * 60),
  );
  await _setTime(
    db,
    'closed',
    TimeContext.create(
        days: _everyDay, startMinute: 6 * 60, endMinute: 8 * 60),
  );
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ProviderContainer container;
  late DateTime Function() clock;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    clock = () => _mondayMorning;
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWith((ref) => () => clock()),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<T> eventually<T>(
    ProviderListenable<T> provider,
    bool Function(T) done,
  ) async {
    final sub = container.listen(provider, (_, _) {});
    addTearDown(sub.close);
    for (var i = 0; i < 800; i++) {
      final value = sub.read();
      if (done(value)) return value;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return sub.read();
  }

  /// Waits until the Time contexts of the seeded Outcomes have loaded, so the
  /// planned-day rule has been applied and not merely not yet run.
  Future<void> awaitContextsLoaded() async {
    await eventually<AsyncValue<Map<String, TimeContext>>>(
      currentTimeContextsProvider,
      (v) => v.hasValue && v.value!.isNotEmpty,
    );
  }

  /// The Up Next Outcome ids, once the planned-day rule has been applied.
  ///
  /// The list comes from a watch, so it is emitted once before the Time
  /// contexts have loaded and once after. "plain" is in the list and
  /// "wednesday" is not only on the settled list, so waiting for that keeps
  /// the transient from being read as the outcome.
  Future<Set<String>> settledUpNextIds() async {
    final value = await eventually<AsyncValue<List<Todo>>>(
      nextForFocusSessionPlanningProvider,
      (v) =>
          v.hasValue &&
          {for (final t in v.value!) t.id}.contains('plain') &&
          !{for (final t in v.value!) t.id}.contains('wednesday'),
    );
    return {for (final t in value.value ?? const <Todo>[]) t.id};
  }

  /// The Next List Outcome ids, once the Time contexts have been applied.
  Future<Set<String>> nextListIds(bool Function(Set<String>) done) async {
    final value = await eventually<AsyncValue<List<Todo>>>(
      nextProvider,
      (v) => v.hasValue && done({for (final t in v.value!) t.id}),
    );
    return {for (final t in value.value ?? const <Todo>[]) t.id};
  }

  /// Waits until the named windows of the current Actions have been read, so
  /// the planned-day rule has been applied to them and not merely not yet run.
  Future<void> awaitWindowsLoaded() async {
    await eventually<AsyncValue<Map<String, ActionTimeWindow>>>(
      currentTimeWindowsProvider,
      (v) => v.hasValue && v.value!.isNotEmpty,
    );
    // A provider that watches a stream is recomputed on the next read once
    // the stream has delivered, so the rule sees the windows.
    container.read(plannedDayTimeProvider);
  }

  /// The Up Next Outcome ids, once the planned-day rule has been applied.
  Future<Set<String>> upNextIds(bool Function(Set<String>) done) async {
    final value = await eventually<AsyncValue<List<Todo>>>(
      nextForFocusSessionPlanningProvider,
      (v) => v.hasValue && done({for (final t in v.value!) t.id}),
    );
    return {for (final t in value.value ?? const <Todo>[]) t.id};
  }

  test('a Time context that opens later today is in Up Next, marked, and off '
      'the Next list', () async {
    await _seedScenario(db);
    await awaitContextsLoaded();

    final planned = await eventually(
      plannedDayTimeProvider,
      (v) => v.opensLaterAt.containsKey('later'),
    );
    expect(planned.opensLaterAt['later'], DateTime(2026, 11, 23, 11));
    expect(planned.opensLaterAt.keys.toSet(), {'later'});
    expect(planned.notInPlannedDay, {'wednesday', 'late', 'closed'});

    expect(await settledUpNextIds(), {'later', 'plain'});

    // The Next list keeps its own rule: the time is not open yet.
    expect(await nextListIds((ids) => !ids.contains('later')), {'plain'});
  });

  test('a Time context that opens only on a Wednesday is not in Up Next, and '
      'the search offers it with its reason', () async {
    await _seedScenario(db);
    await awaitContextsLoaded();

    expect(await settledUpNextIds(), {'later', 'plain'});

    final offered = await eventually<List<OffUpNextCandidate>>(
      offUpNextForFocusSessionPlanningProvider,
      (c) => c.any((candidate) => candidate.todo.id == 'wednesday'),
    );
    expect(
      {for (final c in offered) c.todo.id: c.reason},
      {
        'wednesday': OffUpNextReason.notOpenBeforeShutdown,
        'late': OffUpNextReason.notOpenBeforeShutdown,
        'closed': OffUpNextReason.notOpenBeforeShutdown,
      },
    );
  });

  test('a Time context that opens after the Evening Shutdown time is not in '
      'Up Next', () async {
    await _seedScenario(db);
    await awaitContextsLoaded();

    expect(await settledUpNextIds(), {'later', 'plain'});
  });

  test('a Time context that closed earlier today is not in Up Next',
      () async {
    await _seedScenario(db);
    await awaitContextsLoaded();

    expect(await settledUpNextIds(), {'later', 'plain'});
  });

  test('the day being planned is recomputed when it ends, so a time that '
      'opens after the Evening Shutdown time joins Up Next', () async {
    await _insertOutcome(db, 'late');
    await _setTime(
      db,
      'late',
      TimeContext.create(
          days: _everyDay, startMinute: 19 * 60, endMinute: 21 * 60),
    );
    await _insertOutcome(db, 'plain');

    // Half a second before the Evening Shutdown time, the day being planned
    // ends at 18:00, so a time that opens at 19:00 does not open in it.
    clock = () => DateTime(2026, 11, 23, 17, 59, 59, 500);
    await awaitContextsLoaded();
    container.read(plannedDayTimeProvider);

    final before = container.read(plannedDayTimeProvider);
    expect(before.notInPlannedDay, {'late'});
    expect(before.opensLaterAt, isEmpty);

    // The Evening Shutdown time passes: the day being planned runs on to the
    // next midnight, and the time opens inside it.
    clock = () => DateTime(2026, 11, 23, 18, 0, 0, 10);
    final after = await eventually(
      plannedDayTimeProvider,
      (v) => v.opensLaterAt.containsKey('late'),
    );
    expect(after.opensLaterAt['late'], DateTime(2026, 11, 23, 19));
    expect(after.notInPlannedDay, isEmpty);
  });

  test('an Outcome with no time is in Up Next with no mark', () async {
    await _seedScenario(db);
    await awaitContextsLoaded();

    final planned = await eventually(
      plannedDayTimeProvider,
      (v) => v.opensLaterAt.containsKey('later'),
    );
    expect(planned.opensLaterAt.containsKey('plain'), isFalse);

    expect(await settledUpNextIds(), {'later', 'plain'});
  });

  test('picking the Outcome that opens later today puts it on the Plan',
      () async {
    await _seedScenario(db);
    await awaitContextsLoaded();
    expect(await settledUpNextIds(), {'later', 'plain'});

    final notifier = container.read(focusSessionPlanningProvider.notifier);
    notifier.selectTask('later');
    await notifier.startDay();
    final planned = await db.focusSessionDao.watchActiveSessionTasks().first;
    expect(planned.map((t) => t.id), contains('later'));
  });

  // -------------------------------------------------------------------------
  // A named time window is the same rule as a Time context (issue #55).
  // -------------------------------------------------------------------------

  group('a named time window', () {
    test('a window that opens later today is in Up Next, marked, and off the '
        'Next list', () async {
      final windowId =
          await _createWindow(db, 'Every day', _everyDayElevenToTwenty);
      await _insertOutcome(db, 'later');
      await _setWindow(db, 'later', windowId);
      await _insertOutcome(db, 'plain');
      await awaitWindowsLoaded();

      final planned = await eventually(
        plannedDayTimeProvider,
        (v) => v.opensLaterAt.containsKey('later'),
      );
      expect(planned.opensLaterAt['later'], DateTime(2026, 11, 23, 11));
      expect(planned.opensLaterAt.keys.toSet(), {'later'});
      expect(planned.notInPlannedDay, isEmpty);

      expect(await upNextIds((ids) => ids.contains('later')), {'later', 'plain'});

      // The Next list keeps the rule of #55: the window is closed right now.
      expect(await nextListIds((ids) => !ids.contains('later')), {'plain'});
    });

    test('a window that opens only on a Wednesday is not in Up Next, and the '
        'search offers it with its reason', () async {
      final windowId = await _createWindow(db, 'Wednesday', _wednesdayOnly);
      await _insertOutcome(db, 'wednesday');
      await _setWindow(db, 'wednesday', windowId);
      await _insertOutcome(db, 'plain');
      await awaitWindowsLoaded();

      final planned = await eventually(
        plannedDayTimeProvider,
        (v) => v.notInPlannedDay.contains('wednesday'),
      );
      expect(planned.notInPlannedDay, {'wednesday'});
      expect(planned.opensLaterAt, isEmpty);

      expect(await upNextIds((ids) => !ids.contains('wednesday')), {'plain'});

      final offered = await eventually<List<OffUpNextCandidate>>(
        offUpNextForFocusSessionPlanningProvider,
        (c) => c.any((candidate) => candidate.todo.id == 'wednesday'),
      );
      expect(
        {for (final c in offered) c.todo.id: c.reason},
        {'wednesday': OffUpNextReason.notOpenBeforeShutdown},
      );
    });

    test('a window that opens after the Evening Shutdown time is not in Up '
        'Next', () async {
      final windowId = await _createWindow(db, 'Night shift', _mondayNight);
      await _insertOutcome(db, 'night');
      await _setWindow(db, 'night', windowId);
      await _insertOutcome(db, 'plain');
      await awaitWindowsLoaded();

      final planned = await eventually(
        plannedDayTimeProvider,
        (v) => v.notInPlannedDay.contains('night'),
      );
      expect(planned.notInPlannedDay, {'night'});
      expect(planned.opensLaterAt, isEmpty);

      expect(await upNextIds((ids) => !ids.contains('night')), {'plain'});
    });

    test('a window that runs past midnight is still open in the small hours, '
        'and carries no mark', () async {
      final windowId = await _createWindow(db, 'Night shift', _mondayNight);
      await _insertOutcome(db, 'night');
      await _setWindow(db, 'night', windowId);
      await _insertOutcome(db, 'plain');
      // The window opened on Monday evening and has not closed yet.
      clock = () => _tuesdaySmallHours;
      await awaitWindowsLoaded();

      // The planned day still ends at the Evening Shutdown time.
      final shutdownTime =
          container.read(shutdownSettingsProvider).shutdownTime;
      expect(
        plannedDayEnd(now: _tuesdaySmallHours, shutdownTime: shutdownTime),
        DateTime(2026, 11, 24, 18),
      );

      final planned = container.read(plannedDayTimeProvider);
      expect(planned.notInPlannedDay, isEmpty);
      expect(planned.opensLaterAt, isEmpty);

      expect(await upNextIds((ids) => ids.contains('night')), {'night', 'plain'});
    });

    test('editing the hours of a window drops the mark, with no other write',
        () async {
      final windowId =
          await _createWindow(db, 'Every day', _everyDayElevenToTwenty);
      await _insertOutcome(db, 'later');
      await _setWindow(db, 'later', windowId);
      await _insertOutcome(db, 'plain');
      await awaitWindowsLoaded();

      final before = await eventually(
        plannedDayTimeProvider,
        (v) => v.opensLaterAt.containsKey('later'),
      );
      expect(before.opensLaterAt['later'], DateTime(2026, 11, 23, 11));

      // The window now opens at 08:00, so at 09:00 it is open already. The
      // mark is derived from the hours, so editing them is the only write.
      await db.timeWindowDao.updateTimeWindow(
        windowId: windowId,
        hours: _everyDayEightToTwenty,
      );

      final after = await eventually(
        plannedDayTimeProvider,
        (v) => !v.opensLaterAt.containsKey('later'),
      );
      expect(after.opensLaterAt.containsKey('later'), isFalse);
      expect(after.notInPlannedDay.contains('later'), isFalse);

      expect(await upNextIds((ids) => ids.contains('later')), {'later', 'plain'});
    });
  });
}
