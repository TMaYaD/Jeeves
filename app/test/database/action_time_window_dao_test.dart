/// The named time window of an Outcome's current Action (issue #55).
///
/// The rules under test: the window is keyed by Outcome id, a window that no
/// longer exists or whose hours do not parse is absent (an unreadable window
/// never hides an Outcome), a window beats the Time context beside it, and
/// editing the window's hours re-emits the read.
@TestOn('!browser')
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/time_context.dart';
import 'package:jeeves/models/time_window_hours.dart';

import '../test_helpers.dart';

const _userId = 'test-user';
final _ts = DateTime.utc(2026, 11, 24, 9);

final _storeHours = <int, DayHours>{
  for (var day = 1; day <= 5; day++)
    day: (startMinute: 11 * 60, endMinute: 20 * 60),
};

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;

  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    db = GtdDatabase(NativeDatabase.memory());
  });
  tearDown(() async => db.close());

  /// An Outcome with a current Action, optionally carrying a window and a Time
  /// context.
  Future<void> seedOutcome(
    String actionId, {
    String? windowId,
    String? timeContext,
  }) async {
    await db.into(db.todos).insert(TodosCompanion(
          id: Value('todo-$actionId'),
          title: Value('outcome $actionId'),
          userId: const Value(_userId),
          createdAt: Value(_ts),
          updatedAt: Value(_ts),
        ));
    await db.into(db.actions).insert(ActionsCompanion(
          id: Value(actionId),
          outcomeId: Value('todo-$actionId'),
          userId: const Value(_userId),
          actionText: Value('action $actionId'),
          role: const Value('current'),
          timeWindowId: Value(windowId),
          timeContext: Value(timeContext),
          createdAt: Value(_ts),
        ));
  }

  Future<String?> createWindow(String name) =>
      db.timeWindowDao.createTimeWindow(
        name: name,
        hours: _storeHours,
        userId: _userId,
        now: _ts,
      );

  test('the window is keyed by Outcome id', () async {
    final id = await createWindow('Store hours');
    await seedOutcome('a1', windowId: id);

    final windows = await db.actionDao.watchCurrentTimeWindows().first;

    expect(windows.keys, {'todo-a1'});
    expect(windows['todo-a1']!.id, id);
    expect(windows['todo-a1']!.name, 'Store hours');
    expect(windows['todo-a1']!.hours.days, [1, 2, 3, 4, 5]);
  });

  test('an Outcome with no window is absent', () async {
    await seedOutcome('a1');

    final windows = await db.actionDao.watchCurrentTimeWindows().first;

    expect(windows, isEmpty);
  });

  test('a window that no longer exists is absent', () async {
    final id = await createWindow('Store hours');
    await seedOutcome('a1', windowId: id);
    // The window row goes without the Action being told: the read must not
    // resolve a window that is not there.
    await db.delete(db.timeWindows).go();

    final windows = await db.actionDao.watchCurrentTimeWindows().first;

    expect(windows, isEmpty);
  });

  test('hours the app cannot read are absent', () async {
    final id = await createWindow('Store hours');
    await seedOutcome('a1', windowId: id);
    await db.update(db.timeWindows).write(
      TimeWindowsCompanion(hours: const Value('not json')),
    );

    final windows = await db.actionDao.watchCurrentTimeWindows().first;

    expect(windows, isEmpty);
  });

  test('a window beats the Time context beside it', () async {
    final id = await createWindow('Store hours');
    await seedOutcome(
      'a1',
      windowId: id,
      timeContext:
          TimeContext.create(fromDate: DateTime(2030, 1, 1))!.encode(),
    );

    final windows = await db.actionDao.watchCurrentTimeWindows().first;
    final contexts = await db.actionDao.watchCurrentTimeContexts().first;

    expect(windows.keys, {'todo-a1'});
    // The window governs the Action's time, so the Time context beside it is
    // ignored.
    expect(contexts, isEmpty);
  });

  test('editing the hours re-emits the read', () async {
    final id = await createWindow('Store hours');
    await seedOutcome('a1', windowId: id);

    final emissions = <List<String>>[];
    final sub = db.actionDao.watchCurrentTimeWindows().listen((windows) {
      emissions.add([for (final w in windows.values) w.name]);
    });
    addTearDown(sub.cancel);
    await pumpEventQueue();

    await db.timeWindowDao.updateTimeWindow(
      windowId: id!,
      name: 'Opening hours',
    );
    await pumpEventQueue();

    expect(emissions.last, ['Opening hours']);
  });
}
