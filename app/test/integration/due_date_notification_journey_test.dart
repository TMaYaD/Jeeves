/// Journey: an Outcome's due date drives a notification at 09:00 local on the
/// due day, through the real database and DAO write paths. The OS is replaced
/// by [FakeOsNotifications], which keeps its pending set in memory — so these
/// tests prove what the app hands to the notification service, not Android's
/// alarm delivery.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart' show Intent;
import 'package:jeeves/services/due_date_notifications.dart';
import 'package:jeeves/services/notification_service.dart';

import '../test_helpers.dart';

class _Pending {
  _Pending(this.title, this.body, this.fireAt, this.payload);
  final String title;
  final String body;
  final DateTime fireAt;
  final String? payload;
}

class FakeOsNotifications extends NotificationService {
  FakeOsNotifications() : super.forTesting();

  final pending = <int, _Pending>{};
  String? deviceZone;

  @override
  Future<void> scheduleReminder({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledAt,
    String? payload,
  }) async {
    pending[id] = _Pending(title, body, scheduledAt, payload);
  }

  @override
  Future<void> cancelReminder(int id) async {
    pending.remove(id);
    delivered.remove(id);
  }

  /// Notifications that already fired and sit in the tray.
  final delivered = <int>{};

  @override
  Future<({Set<int> pending, Set<int> delivered})>
      dueDateNotificationsOnDevice() async =>
          (pending: pending.keys.toSet(), delivered: delivered.toSet());

  @override
  Future<bool> refreshLocalTimezone() async {
    final zone = deviceZone;
    if (zone == null || zone == tz.local.name) return false;
    tz.setLocalLocation(tz.getLocation(zone));
    return true;
  }
}

DateTime _dueDay(tz.Location location, int y, int m, int d) =>
    DateTime.fromMillisecondsSinceEpoch(
      tz.TZDateTime(location, y, m, d).millisecondsSinceEpoch,
      isUtc: true,
    );

void main() {
  setUpAll(() {
    configureSqliteForTests();
    tz_data.initializeTimeZones();
  });

  late tz.Location kolkata;
  late GtdDatabase db;
  late FakeOsNotifications os;
  late DueDateNotificationReconciler reconciler;
  var now = DateTime.utc(2026, 11, 10, 6); // 11:30 in Kolkata.

  DueDateNotificationReconciler startReconciler() =>
      DueDateNotificationReconciler(
        notifications: os,
        outcomes: db.todoDao.watchDueDateNotificationCandidates(),
        now: () => now,
      )..start(listenToLifecycle: false);

  /// Lets the Drift stream emit and the reconciler finish, twice over so an
  /// emission triggered by the first pass is also settled.
  Future<void> settle() async {
    for (var i = 0; i < 2; i++) {
      await pumpEventQueue();
      await reconciler.settled();
    }
  }

  Future<void> insert(String id, {DateTime? dueDate}) =>
      db.todoDao.insertOutcome(
          id: id, title: 'Title $id', userId: 'local', dueDate: dueDate);

  setUp(() {
    now = DateTime.utc(2026, 11, 10, 6);
    kolkata = tz.getLocation('Asia/Kolkata');
    tz.setLocalLocation(kolkata);
    db = GtdDatabase(NativeDatabase.memory());
    os = FakeOsNotifications()..deviceZone = 'Asia/Kolkata';
    reconciler = startReconciler();
  });

  tearDown(() async {
    reconciler.dispose();
    await db.close();
  });

  test('a due date produces one notification at 09:00 on the due day',
      () async {
    await insert('a', dueDate: _dueDay(kolkata, 2026, 11, 20));
    await settle();

    expect(os.pending, hasLength(1));
    final scheduled = os.pending[dueDateNotificationId('a')]!;
    expect(scheduled.title, 'Title a');
    expect(scheduled.body, 'Due today');
    expect(scheduled.payload, 'outcome:a');
    expect(scheduled.fireAt.isAtSameMomentAs(tz.TZDateTime(kolkata, 2026, 11, 20, 9)),
        isTrue);
  });

  test('changing the due date replaces the notification', () async {
    await insert('a', dueDate: _dueDay(kolkata, 2026, 11, 20));
    await settle();
    await db.todoDao.rescheduleTask('a', _dueDay(kolkata, 2026, 11, 25));
    await settle();

    expect(os.pending, hasLength(1));
    expect(
        os.pending.values.single.fireAt
            .isAtSameMomentAs(tz.TZDateTime(kolkata, 2026, 11, 25, 9)),
        isTrue);
  });

  test('renaming the Outcome updates the notification title', () async {
    await insert('a', dueDate: _dueDay(kolkata, 2026, 11, 20));
    await settle();
    await db.todoDao.updateFields('a', title: 'Renamed');
    await settle();

    expect(os.pending.values.single.title, 'Renamed');
  });

  test('clearing the due date cancels it', () async {
    await insert('a', dueDate: _dueDay(kolkata, 2026, 11, 20));
    await settle();
    await db.todoDao.updateFields('a', clearDueDate: true);
    await settle();

    expect(os.pending, isEmpty);
  });

  test('completing cancels it', () async {
    await insert('a', dueDate: _dueDay(kolkata, 2026, 11, 20));
    await settle();
    await db.todoDao.markDone('a');
    await settle();

    expect(os.pending, isEmpty);
  });

  test('trashing cancels it', () async {
    await insert('a', dueDate: _dueDay(kolkata, 2026, 11, 20));
    await settle();
    await db.todoDao.setIntent('a', Intent.trash);
    await settle();

    expect(os.pending, isEmpty);
  });

  test('deleting cancels it', () async {
    await insert('a', dueDate: _dueDay(kolkata, 2026, 11, 20));
    await settle();
    await db.todoDao.deleteOutcome('a');
    await settle();

    expect(os.pending, isEmpty);
  });

  test('an Outcome with no due date gets none', () async {
    await insert('a');
    await settle();

    expect(os.pending, isEmpty);
  });

  test('after a restart the pending set matches the database', () async {
    await insert('keep', dueDate: _dueDay(kolkata, 2026, 11, 20));
    await insert('lost', dueDate: _dueDay(kolkata, 2026, 11, 21));
    await settle();

    // App closes. The OS lost one notification, and another Outcome was
    // deleted (say, by sync) while the app was not running.
    reconciler.dispose();
    os.pending.remove(dueDateNotificationId('lost'));
    os.pending[dueDateNotificationId('orphan')] = _Pending(
        'Gone', 'Due today', now.add(const Duration(days: 3)), 'outcome:orphan');

    reconciler = startReconciler();
    await settle();

    expect(os.pending.keys.toSet(), {
      dueDateNotificationId('keep'),
      dueDateNotificationId('lost'),
    });
  });

  test('moving the due date into the past cancels the old alarm', () async {
    await insert('a', dueDate: _dueDay(kolkata, 2026, 11, 20));
    await settle();
    await db.todoDao.rescheduleTask('a', _dueDay(kolkata, 2026, 11, 10));
    await settle();

    expect(os.pending, isEmpty);
  });

  test('after a restart an alarm for a past due date is cancelled', () async {
    await insert('a', dueDate: _dueDay(kolkata, 2026, 11, 20));
    await settle();
    reconciler.dispose();
    // Edited into the past by another run of the app, which died before it
    // could cancel.
    await db.todoDao.rescheduleTask('a', _dueDay(kolkata, 2026, 11, 10));

    reconciler = startReconciler();
    await settle();

    expect(os.pending, isEmpty);
  });

  test('a delivered notification stays while its Outcome is overdue and open',
      () async {
    await insert('a', dueDate: _dueDay(kolkata, 2026, 11, 10));
    os.delivered.add(dueDateNotificationId('a'));
    reconciler.dispose();
    reconciler = startReconciler();
    await settle();

    expect(os.delivered, {dueDateNotificationId('a')});

    await db.todoDao.markDone('a');
    await settle();
    expect(os.delivered, isEmpty);
  });

  test('a late alarm past 09:00 is still cancelled when the date moves back',
      () async {
    await insert('a', dueDate: _dueDay(kolkata, 2026, 11, 10));
    now = DateTime.utc(2026, 11, 9, 6);
    reconciler.dispose();
    reconciler = startReconciler();
    await settle();
    expect(os.pending, hasLength(1));

    // 09:01 on the due day: the OS has not delivered the alarm yet.
    now = DateTime.utc(2026, 11, 10, 3, 31);
    await db.todoDao.rescheduleTask('a', _dueDay(kolkata, 2026, 11, 9));
    await settle();

    expect(os.pending, isEmpty);
    expect(os.delivered, isEmpty);
  });

  test('an alarm seen as both pending and delivered stays in the tray',
      () async {
    await insert('a', dueDate: _dueDay(kolkata, 2026, 11, 10));
    final id = dueDateNotificationId('a');
    os.pending[id] = _Pending(
        'Title a', 'Due today', now.subtract(const Duration(hours: 1)), 'outcome:a');
    os.delivered.add(id);
    reconciler.dispose();
    reconciler = startReconciler();
    await settle();

    expect(os.delivered, {id});
  });

  test('a timezone change is picked up on the next resume', () async {
    await insert('a', dueDate: _dueDay(kolkata, 2026, 11, 20));
    await settle();

    // The device travels to Los Angeles; the next resume re-reads the zone.
    os.deviceZone = 'America/Los_Angeles';
    await reconciler.onResumed();
    await settle();

    final la = tz.getLocation('America/Los_Angeles');
    // The due day is read in the zone the device is now in.
    expect(
        os.pending.values.single.fireAt
            .isAtSameMomentAs(tz.TZDateTime(la, 2026, 11, 19, 9)),
        isTrue);
  });
}
