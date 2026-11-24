/// The time window DAO: create, edit, delete and watch (issue #239).
///
/// The rules under test: a named window is listed with its hours as canonical
/// JSON, a rename shows the new name, a delete detaches the window from every
/// Action that used it, and a write the model cannot accept — hours that do
/// not encode, a blank or over-long name — stores nothing.
@TestOn('!browser')
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/time_window_hours.dart';
import 'package:jeeves/sync/collection_codecs.dart';
import 'package:jeeves/sync/domain_op_capture.dart';

import '../test_helpers.dart';

const _userId = 'test-user';
final _ts = DateTime.utc(2026, 11, 24, 9);

/// Monday to Friday, 11:00 to 20:00.
final _storeHours = <int, DayHours>{
  for (var day = 1; day <= 5; day++)
    day: (startMinute: 11 * 60, endMinute: 20 * 60),
};

void main() {
  setUpAll(configureSqliteForTests);

  late RecordingDomainOpCapture capture;
  late GtdDatabase db;

  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    capture = RecordingDomainOpCapture();
    db = GtdDatabase(NativeDatabase.memory(), opCapture: capture);
  });
  tearDown(() async => db.close());

  /// An Action pointing at [windowId], written straight into the column — the
  /// Action-side setters arrive with step 4.
  Future<void> seedAction(String actionId, {String? windowId}) async {
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
          createdAt: Value(_ts),
        ));
  }

  Future<String?> windowIdOf(String actionId) async {
    final row =
        await (db.select(db.actions)..where((a) => a.id.equals(actionId)))
            .getSingle();
    return row.timeWindowId;
  }

  Future<String?> createStoreHours() => db.timeWindowDao.createTimeWindow(
        name: 'Store hours',
        hours: _storeHours,
        userId: _userId,
        now: _ts,
      );

  test('a created window is listed by watchTimeWindows', () async {
    final id = await createStoreHours();

    final windows = await db.timeWindowDao.watchTimeWindows().first;
    expect(windows, hasLength(1));
    expect(windows.first.id, id);
    expect(windows.first.name, 'Store hours');
    // The hours are stored as the canonical JSON, so two devices that build
    // the same hours write the same bytes.
    expect(windows.first.hours,
        '[{"day":1,"start":"11:00","end":"20:00"},'
        '{"day":2,"start":"11:00","end":"20:00"},'
        '{"day":3,"start":"11:00","end":"20:00"},'
        '{"day":4,"start":"11:00","end":"20:00"},'
        '{"day":5,"start":"11:00","end":"20:00"}]');
    expect(TimeWindowHours.tryParse(windows.first.hours)?.days, [1, 2, 3, 4, 5]);
  });

  test('a rename shows the new name', () async {
    final id = await createStoreHours();
    capture.clear();

    final written = await db.timeWindowDao
        .updateTimeWindow(windowId: id!, name: '  Opening hours  ');

    expect(written, isTrue);
    final windows = await db.timeWindowDao.watchTimeWindows().first;
    expect(windows.single.name, 'Opening hours');
    final op = capture.forCollection(timeWindowsCollection).single;
    expect(op.entityId, id);
    expect(op.fields['name'], 'Opening hours');
  });

  test('new hours are written and asserted', () async {
    final id = await createStoreHours();
    capture.clear();

    final written = await db.timeWindowDao.updateTimeWindow(
      windowId: id!,
      hours: <int, DayHours>{6: (startMinute: 10 * 60, endMinute: 14 * 60)},
    );

    expect(written, isTrue);
    final window =
        await (db.select(db.timeWindows)..where((w) => w.id.equals(id)))
            .getSingle();
    expect(window.hours, '[{"day":6,"start":"10:00","end":"14:00"}]');
    final op = capture.forCollection(timeWindowsCollection).single;
    expect(op.fields['hours'], '[{"day":6,"start":"10:00","end":"14:00"}]');
  });

  test('delete removes the window and clears the reference on the two Actions '
      'that used it', () async {
    final id = await createStoreHours();
    // A second window, with an Action of its own: the delete detaches the
    // window it names and nothing else.
    final otherId = await db.timeWindowDao.createTimeWindow(
      name: 'Warehouse hours',
      hours: <int, DayHours>{7: (startMinute: 9 * 60, endMinute: 12 * 60)},
      userId: _userId,
      now: _ts,
    );
    expect(otherId, isNotNull);
    await seedAction('a1', windowId: id);
    await seedAction('a2', windowId: id);
    await seedAction('a3');
    await seedAction('a4', windowId: otherId);
    capture.clear();

    await db.timeWindowDao.deleteTimeWindow(id!, now: _ts);

    expect(
      await (db.select(db.timeWindows)..where((w) => w.id.equals(id))).get(),
      isEmpty,
    );
    expect(await windowIdOf('a1'), isNull);
    expect(await windowIdOf('a2'), isNull);
    expect(await windowIdOf('a3'), isNull);
    // The other window's Action keeps its reference.
    expect(await windowIdOf('a4'), otherId);
    expect(
      await (db.select(db.timeWindows)..where((w) => w.id.equals(otherId!)))
          .get(),
      hasLength(1),
    );

    final windowOps = capture.forCollection(timeWindowsCollection);
    expect(windowOps, hasLength(1));
    expect(windowOps.single.entityId, id);
    expect(windowOps.single.tombstone, isTrue);
    final actionOps = capture.forCollection(actionsCollection);
    expect(actionOps, hasLength(2));
    expect({for (final op in actionOps) op.entityId}, {'a1', 'a2'});
    for (final op in actionOps) {
      expect(op.fields.containsKey('time_window_id'), isTrue);
      expect(op.fields['time_window_id'], isNull);
    }
  });

  test('hours that do not encode are refused and write nothing', () async {
    // A day that starts and ends at the same minute.
    expect(
      await db.timeWindowDao.createTimeWindow(
        name: 'Never',
        hours: <int, DayHours>{1: (startMinute: 600, endMinute: 600)},
        userId: _userId,
        now: _ts,
      ),
      isNull,
    );
    // A day outside Monday to Sunday.
    expect(
      await db.timeWindowDao.createTimeWindow(
        name: 'Never',
        hours: <int, DayHours>{8: (startMinute: 600, endMinute: 1200)},
        userId: _userId,
        now: _ts,
      ),
      isNull,
    );
    // A clock outside the day.
    expect(
      await db.timeWindowDao.createTimeWindow(
        name: 'Never',
        hours: <int, DayHours>{1: (startMinute: 600, endMinute: 25 * 60)},
        userId: _userId,
        now: _ts,
      ),
      isNull,
    );
    // No days at all.
    expect(
      await db.timeWindowDao.createTimeWindow(
        name: 'Never',
        hours: const <int, DayHours>{},
        userId: _userId,
        now: _ts,
      ),
      isNull,
    );

    expect(await db.select(db.timeWindows).get(), isEmpty);
    expect(capture.recorded, isEmpty);
  });

  test('a blank or over-long name is refused and writes nothing', () async {
    expect(
      await db.timeWindowDao.createTimeWindow(
        name: '   ',
        hours: _storeHours,
        userId: _userId,
        now: _ts,
      ),
      isNull,
    );
    expect(
      await db.timeWindowDao.createTimeWindow(
        name: 'x' * 101,
        hours: _storeHours,
        userId: _userId,
        now: _ts,
      ),
      isNull,
    );

    expect(await db.select(db.timeWindows).get(), isEmpty);
    expect(capture.recorded, isEmpty);
  });

  test('an update that the model cannot accept writes nothing', () async {
    final id = await createStoreHours();
    capture.clear();

    expect(
      await db.timeWindowDao.updateTimeWindow(windowId: id!, name: ''),
      isFalse,
    );
    expect(
      await db.timeWindowDao.updateTimeWindow(
        windowId: id,
        hours: <int, DayHours>{1: (startMinute: 600, endMinute: 600)},
      ),
      isFalse,
    );

    final window =
        await (db.select(db.timeWindows)..where((w) => w.id.equals(id)))
            .getSingle();
    expect(window.name, 'Store hours');
    expect(capture.recorded, isEmpty);
  });
}
