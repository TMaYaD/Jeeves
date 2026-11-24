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
import 'package:jeeves/models/time_context.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/time_context_provider.dart';
import 'package:jeeves/services/notification_service.dart';

import '../test_helpers.dart';

const _userId = 'local';

/// Every ISO weekday: Monday is 1.
const _everyDay = {1, 2, 3, 4, 5, 6, 7};

/// Monday, 23 November 2026, 09:00. The Evening Shutdown time is the default
/// 18:00, so the planned day runs from 09:00 to 18:00.
final _mondayMorning = DateTime(2026, 11, 23, 9);

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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWith((ref) => () => _mondayMorning),
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
}
