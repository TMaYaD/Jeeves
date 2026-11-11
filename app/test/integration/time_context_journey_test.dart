/// TimeContext journey (#238), over a real in-memory store.
///
/// An Outcome's current Action carries a TimeContext. While it is unsatisfied
/// the Outcome is off the Next List and Daily Planning's Up Next, still findable
/// by the plan-building search ("Outside its time context"), and it comes back
/// by itself when the time arrives. Provider plus real DB, no widgets: a live
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
import 'package:jeeves/services/notification_service.dart';

import '../test_helpers.dart';

const _userId = 'local';

Future<String> _insertOutcome(GtdDatabase db, String id) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Outcome $id'),
        clarified: const Value(true),
        intent: const Value('next'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  await seedCurrentAction(db,
      outcomeId: id, text: 'work on $id', userId: _userId);
  return (await db.actionDao.getCurrentAction(id))!.id;
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ProviderContainer container;
  late DateTime Function() clock;

  void startContainer() {
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWith((ref) => () => clock()),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ]);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    // 2026-11-11 is a Wednesday.
    clock = () => DateTime(2026, 11, 11, 12);
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

  Future<Set<String>> nextIds(bool Function(Set<String>) done) async {
    final value = await eventually<AsyncValue<List<Todo>>>(
      nextProvider,
      (v) => v.hasValue && done({for (final t in v.value!) t.id}),
    );
    return {for (final t in value.value ?? const <Todo>[]) t.id};
  }

  test('a from-date hides the Outcome until the day starts, then it returns '
      'with no other write', () async {
    final actionId = await _insertOutcome(db, 'o1');
    await _insertOutcome(db, 'plain');
    // Real wall clock, parked 2 s before tomorrow's local midnight.
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    final midnight = DateTime(tomorrow.year, tomorrow.month, tomorrow.day);
    final start = midnight.subtract(const Duration(milliseconds: 2000));
    final stopwatch = Stopwatch()..start();
    clock = () => start.add(stopwatch.elapsed);
    startContainer();

    await db.actionDao
        .setTimeContext(actionId, TimeContext.create(fromDate: midnight));

    expect(await nextIds((ids) => !ids.contains('o1')), {'plain'});
    // Past midnight, nothing was written in between.
    expect(await nextIds((ids) => ids.contains('o1')), {'o1', 'plain'});
  });

  test('a weekly window: absent from Up Next on a Wednesday, offered by the '
      'search with its reason, selectable for today', () async {
    final actionId = await _insertOutcome(db, 'o1');
    startContainer();
    await db.actionDao.setTimeContext(
      actionId,
      TimeContext.create(days: {2, 4}, startMinute: 540, endMinute: 1020),
    );

    final upNext = await eventually<AsyncValue<List<Todo>>>(
      nextForFocusSessionPlanningProvider,
      (v) => v.hasValue && v.value!.isEmpty,
    );
    expect(upNext.value, isEmpty);

    final offered = await eventually<List<OffUpNextCandidate>>(
      offUpNextForFocusSessionPlanningProvider,
      (c) => c.isNotEmpty,
    );
    expect({for (final c in offered) c.todo.id: c.reason},
        {'o1': OffUpNextReason.outsideTimeContext});

    final notifier = container.read(focusSessionPlanningProvider.notifier);
    notifier.selectTask('o1');
    await notifier.startDay();
    final planned = await db.focusSessionDao.watchActiveSessionTasks().first;
    expect(planned.map((t) => t.id), contains('o1'));
  });

  test('clearing the TimeContext brings the Outcome back immediately',
      () async {
    final actionId = await _insertOutcome(db, 'o1');
    startContainer();
    await db.actionDao
        .setTimeContext(actionId, TimeContext.create(days: {2, 4}));
    expect(await nextIds((ids) => ids.isEmpty), isEmpty);

    await db.actionDao.setTimeContext(actionId, null);
    expect(await nextIds((ids) => ids.contains('o1')), {'o1'});
  });

  test('a stored value the app cannot parse never hides the Outcome',
      () async {
    await _insertOutcome(db, 'o1');
    startContainer();
    await db.customStatement("UPDATE actions SET time_context = 'garbage'");
    expect(await nextIds((ids) => ids.contains('o1')), {'o1'});
  });
}
