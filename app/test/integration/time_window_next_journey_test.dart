/// Named time window on Next (issue #55), over a real in-memory store.
///
/// An Outcome whose current Action carries a named time window is off the Next
/// List while the window is closed, and comes back on its own when the window
/// opens. Up Next is untouched: hiding is on Next only.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/time_window_hours.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/time_window_provider.dart';
import 'package:jeeves/services/notification_service.dart';

import '../test_helpers.dart';

const _userId = 'local';

/// Monday to Friday, 09:00 to 17:00.
final _workHours = <int, DayHours>{
  for (var day = 1; day <= 5; day++)
    day: (startMinute: 9 * 60, endMinute: 17 * 60),
};

/// Monday only, 22:00 to 02:00 — a window that runs past midnight.
final _nightHours = <int, DayHours>{
  1: (startMinute: 22 * 60, endMinute: 2 * 60),
};

Future<String> _insertOutcome(GtdDatabase db, String id) async {
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
    // 2026-11-11 is a Wednesday, 2026-11-16 a Monday.
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

  Future<String> createWindow(String name, Map<int, DayHours> hours) async {
    final id = await db.timeWindowDao.createTimeWindow(
      name: name,
      hours: hours,
      userId: _userId,
    );
    expect(id, isNotNull);
    return id!;
  }

  test('a closed window hides the Outcome from Next, and the window opening '
      'brings it back on its own', () async {
    final windowId = await createWindow('Work hours', _workHours);
    final actionId = await _insertOutcome(db, 'o1');
    await db.actionDao.setTimeWindow(actionId, windowId);
    await _insertOutcome(db, 'plain');
    // Wednesday 17:00 — the window has just closed.
    clock = () => DateTime(2026, 11, 11, 17, 0);
    startContainer();

    expect(await nextIds((ids) => !ids.contains('o1')), {'plain'});

    // Two seconds before the window opens on Thursday: the boundary timer is
    // armed for the opening, and it fires on its own.
    final opens = DateTime(2026, 11, 12, 9, 0);
    final stopwatch = Stopwatch()..start();
    final start = opens.subtract(const Duration(seconds: 2));
    clock = () => start.add(stopwatch.elapsed);
    container.invalidate(timeWindowBoundaryTickProvider);

    expect(await nextIds((ids) => ids.contains('o1')), {'o1', 'plain'});
  });

  test('a window that runs past midnight is open from its own evening until '
      'the small hours', () async {
    final windowId = await createWindow('Night shift', _nightHours);
    final actionId = await _insertOutcome(db, 'o1');
    await db.actionDao.setTimeWindow(actionId, windowId);
    await _insertOutcome(db, 'plain');
    // Monday 22:00 — the window opens.
    clock = () => DateTime(2026, 11, 16, 22, 0);
    startContainer();

    expect(await nextIds((ids) => ids.contains('o1')), {'o1', 'plain'});

    // Monday 23:30 — still open.
    clock = () => DateTime(2026, 11, 16, 23, 30);
    container.invalidate(timeWindowBoundaryTickProvider);
    expect(await nextIds((ids) => ids.contains('o1')), {'o1', 'plain'});

    // Tuesday 01:00 — the window started on Monday and is still open.
    clock = () => DateTime(2026, 11, 17, 1, 0);
    container.invalidate(timeWindowBoundaryTickProvider);
    expect(await nextIds((ids) => ids.contains('o1')), {'o1', 'plain'});

    // Tuesday 02:00 — closed.
    clock = () => DateTime(2026, 11, 17, 2, 0);
    container.invalidate(timeWindowBoundaryTickProvider);
    expect(await nextIds((ids) => !ids.contains('o1')), {'plain'});
  });

  test('the Outcome stays in Up Next while its window is closed', () async {
    final windowId = await createWindow('Work hours', _workHours);
    final actionId = await _insertOutcome(db, 'o1');
    await db.actionDao.setTimeWindow(actionId, windowId);
    // Wednesday 17:00 — the window is closed.
    clock = () => DateTime(2026, 11, 11, 17, 0);
    startContainer();

    final upNext = await eventually<AsyncValue<List<Todo>>>(
      nextForFocusSessionPlanningProvider,
      (v) => v.hasValue && v.value!.isNotEmpty,
    );
    expect(upNext.value!.map((t) => t.id), contains('o1'));
  });

  test('a window the app cannot read never hides the Outcome', () async {
    final windowId = await createWindow('Work hours', _workHours);
    final actionId = await _insertOutcome(db, 'o1');
    await db.actionDao.setTimeWindow(actionId, windowId);
    clock = () => DateTime(2026, 11, 11, 17, 0);
    startContainer();

    await db.customStatement(
      "UPDATE time_windows SET hours = 'garbage' WHERE id = '$windowId'",
    );
    db.notifyTimeWindowsViewWrite();

    expect(await nextIds((ids) => ids.contains('o1')), {'o1'});
  });

  test('the boundary signal advances on every re-read, even when the next '
      'boundary is the same instant', () async {
    final windowId = await createWindow('Work hours', _workHours);
    final actionId = await _insertOutcome(db, 'o1');
    await db.actionDao.setTimeWindow(actionId, windowId);
    clock = () => DateTime(2026, 11, 11, 17, 0);
    startContainer();

    final first = container.read(timeWindowBoundaryTickProvider);
    container.invalidate(timeWindowBoundaryTickProvider);
    await container.pump();
    final second = container.read(timeWindowBoundaryTickProvider);

    // The next boundary is the same instant as before — the clock did not
    // move — but the signal has to change: Riverpod only wakes a dependent
    // when the value it watches changes, and a signal that repeated would
    // leave the set of hidden Outcomes as it was.
    expect(second, isNot(first));
  });

  testWidgets('the app resuming re-reads the windows', (tester) async {
    final windowId = await createWindow('Work hours', _workHours);
    final actionId = await _insertOutcome(db, 'o1');
    await db.actionDao.setTimeWindow(actionId, windowId);
    // Wednesday 17:00 — the window has just closed.
    clock = () => DateTime(2026, 11, 11, 17, 0);
    startContainer();
    // The observer that re-arms the boundary when the app comes back.
    container.read(timeBoundaryResumeProvider);
    // Reading the set starts the window stream; let it arrive.
    container.read(outsideTimeWindowOutcomeIdsProvider);
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();

    expect(container.read(outsideTimeWindowOutcomeIdsProvider), contains('o1'));

    // The phone changed its time zone while the app was away, so the window
    // is open now. The app comes back and re-reads the windows.
    clock = () => DateTime(2026, 11, 11, 9, 30);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(
      container.read(outsideTimeWindowOutcomeIdsProvider),
      isNot(contains('o1')),
    );

    // The container goes before the test ends, so that neither the boundary
    // timer nor the Drift close timer outlives it.
    container.dispose();
    await tester.pump();
  });
}
