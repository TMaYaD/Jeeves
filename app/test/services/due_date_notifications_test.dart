import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart' show Intent;
import 'package:jeeves/services/due_date_notifications.dart';

import '../test_helpers.dart';

/// Local midnight of the given day in [location], as the instant the date
/// pickers store.
DateTime dueDay(tz.Location location, int y, int m, int d) =>
    DateTime.fromMillisecondsSinceEpoch(
      tz.TZDateTime(location, y, m, d).millisecondsSinceEpoch,
      isUtc: true,
    );

void main() {
  setUpAll(() {
    configureSqliteForTests();
    tz_data.initializeTimeZones();
  });

  group('dueDateNotificationId', () {
    test('is stable, in range, and differs between Outcomes', () {
      final id = dueDateNotificationId('3f2b6c1e-0000-4000-8000-000000000001');
      expect(id, dueDateNotificationId('3f2b6c1e-0000-4000-8000-000000000001'));
      expect(id, inInclusiveRange(10000, 0x7FFFFFFE));
      expect(id,
          isNot(dueDateNotificationId('3f2b6c1e-0000-4000-8000-000000000002')));
    });

    test('is pinned, so it cannot drift between releases', () {
      // FNV-1a 32-bit of "a" is 0xe40c292c.
      expect(dueDateNotificationId('a'),
          10000 + 0xe40c292c % (0x7FFFFFFF - 10000));
    });
  });

  group('dueDateNotificationFireAt', () {
    test('is 09:00 on the due day in Asia/Kolkata', () {
      final kolkata = tz.getLocation('Asia/Kolkata');
      final fireAt =
          dueDateNotificationFireAt(dueDay(kolkata, 2026, 11, 20), kolkata);
      expect(fireAt, tz.TZDateTime(kolkata, 2026, 11, 20, 9));
    });

    test('is 09:00 on the due day in America/Los_Angeles', () {
      final la = tz.getLocation('America/Los_Angeles');
      final fireAt = dueDateNotificationFireAt(dueDay(la, 2026, 11, 20), la);
      expect(fireAt, tz.TZDateTime(la, 2026, 11, 20, 9));
    });

    test('uses the day the device now sits in when the zone has changed', () {
      // Midnight in Kolkata is the previous evening in Los Angeles; the day the
      // device is in decides, since that is the day the UI shows.
      final kolkata = tz.getLocation('Asia/Kolkata');
      final la = tz.getLocation('America/Los_Angeles');
      final fireAt =
          dueDateNotificationFireAt(dueDay(kolkata, 2026, 11, 20), la);
      expect(fireAt, tz.TZDateTime(la, 2026, 11, 19, 9));
    });
  });

  group('outcomeIdFromNotificationPayload', () {
    test('round-trips and ignores other payloads', () {
      expect(outcomeIdFromNotificationPayload(dueDateNotificationPayload('x1')),
          'x1');
      expect(outcomeIdFromNotificationPayload('focus'), isNull);
      expect(outcomeIdFromNotificationPayload('nudge:planning'), isNull);
      expect(outcomeIdFromNotificationPayload('outcome:'), isNull);
      expect(outcomeIdFromNotificationPayload(null), isNull);
    });
  });

  group('with a database', () {
    late GtdDatabase db;
    setUp(() => db = GtdDatabase(NativeDatabase.memory()));
    tearDown(() async => db.close());

    Future<void> insert(String id, {DateTime? dueDate}) =>
        db.todoDao.insertOutcome(
            id: id, title: 'Title $id', userId: 'local', dueDate: dueDate);

    Future<List<Todo>> candidates() =>
        db.todoDao.watchDueDateNotificationCandidates().first;

    test('candidates are open due-dated Outcomes; the rest are excluded',
        () async {
      final due = DateTime.utc(2026, 11, 20);
      await insert('open', dueDate: due);
      await insert('undated');
      await insert('done', dueDate: due);
      await insert('trashed', dueDate: due);
      await insert('maybe', dueDate: due);
      await db.todoDao.markDone('done');
      await db.todoDao.setIntent('trashed', Intent.trash);
      await db.todoDao.setIntent('maybe', Intent.maybe);

      expect({for (final t in await candidates()) t.id}, {'open', 'maybe'});
    });

    group('planDueDateNotifications', () {
      final kolkata = tz.getLocation('Asia/Kolkata');
      final now = tz.TZDateTime(kolkata, 2026, 11, 10, 12);

      test('keeps, but does not schedule, an Outcome whose 09:00 has passed',
          () async {
        await insert('today', dueDate: dueDay(kolkata, 2026, 11, 10));
        final plan = planDueDateNotifications(await candidates(),
            location: kolkata, now: now);
        expect(plan.toSchedule, isEmpty);
        expect(plan.keepIds, {dueDateNotificationId('today')});
      });

      test('schedules only the nearest N, soonest first', () async {
        for (var day = 5; day >= 1; day--) {
          await insert('o$day', dueDate: dueDay(kolkata, 2026, 11, 10 + day));
        }
        final plan = planDueDateNotifications(await candidates(),
            location: kolkata, now: now, maxScheduled: 3);
        expect(plan.toSchedule.map((p) => p.outcomeId), ['o1', 'o2', 'o3']);
        expect(plan.keepIds, plan.toSchedule.map((p) => p.id).toSet());
      });
    });
  });
}
