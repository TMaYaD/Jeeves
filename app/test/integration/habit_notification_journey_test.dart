/// Journey: a Habit's clock time drives a notification on the days it is for,
/// through the real database and the real write paths.
///
/// The OS is replaced by [FakeOsNotifications], which keeps its pending set in
/// memory — so these tests prove what the app hands to the notification
/// service, not Android's alarm delivery.
library;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'package:jeeves/database/daos/habit_dao.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/habit_commitment.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/services/habit_notifications.dart';
import 'package:jeeves/services/notification_service.dart';

import '../test_helpers.dart';

const _userId = 'local';

/// The OS, stood in for: keeps its pending set and its tray in memory.
class FakeOsNotifications extends NotificationService {
  FakeOsNotifications() : super.forTesting();

  /// The alarms the OS holds, by notification id.
  final pending = <int, String>{};

  /// The notifications that already fired and sit in the tray.
  final delivered = <int>{};

  /// The titles the OS was given, by notification id.
  final titles = <int, String>{};

  /// The device's time zone, read on the next resume.
  String? deviceZone;

  @override
  Future<void> scheduleHabitNotification({
    required int id,
    required String title,
    required String body,
    required DateTime fireAt,
    required String payload,
  }) async {
    pending[id] = payload;
    titles[id] = title;
  }

  @override
  Future<void> cancelReminder(int id) async {
    pending.remove(id);
    delivered.remove(id);
  }

  @override
  Future<HabitNotificationsOnDevice> habitNotificationsOnDevice() async => (
        pending: pending.keys.toSet(),
        pendingPayloads: Map.of(pending),
        delivered: delivered.toSet(),
      );

  @override
  Future<bool> refreshLocalTimezone() async {
    final zone = deviceZone;
    if (zone == null || zone == tz.local.name) return false;
    tz.setLocalLocation(tz.getLocation(zone));
    return true;
  }
}

/// The days the OS holds a notification for, soonest first.
extension on FakeOsNotifications {
  List<String> get days => [
        for (final payload in pending.values)
          parseHabitNotificationPayload(payload)!.day,
      ]..sort();

}

void main() {
  setUpAll(() {
    configureSqliteForTests();
    TestWidgetsFlutterBinding.ensureInitialized();
    tz_data.initializeTimeZones();
  });

  late tz.Location kolkata;
  late GtdDatabase db;
  late FakeOsNotifications os;
  late ProviderContainer container;
  // Friday 20 November 2026, 06:30 local — before the 07:00 a clock-time
  // Habit notifies at.
  var now = DateTime.utc(2026, 11, 20, 1);

  setUp(() {
    kolkata = tz.getLocation('Asia/Kolkata');
    tz.setLocalLocation(kolkata);
    db = GtdDatabase(NativeDatabase.memory());
    os = FakeOsNotifications()..deviceZone = 'Asia/Kolkata';
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        notificationServiceProvider.overrideWithValue(os),
        clockProvider.overrideWithValue(() => now),
      ],
    );
    container.read(habitNotificationReconcilerProvider);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  /// Lets the Drift stream emit and the reconciler finish.
  Future<void> settle() async {
    for (var i = 0; i < 2; i++) {
      await pumpEventQueue();
      await container.read(habitNotificationReconcilerProvider)?.settled();
    }
  }

  Future<void> setClockTime(
    String habitId,
    String clockTime, {
    String chosenOn = '2026-11-20',
  }) =>
      db.habitDao.setAnchor(
        habitId: habitId,
        userId: _userId,
        today: chosenOn,
        now: now,
        kind: HabitAnchorKind.clockTime,
        clockTime: clockTime,
      );

  /// A Habit with a clock time of 07:00 — the anchor is what makes it
  /// notify. A null [clockTime] leaves the Habit without one.
  Future<String> createHabit({
    required String title,
    String chosenOn = '2026-11-20',
    String? clockTime = '07:00',
    HabitCommitmentDraft commitment = defaultNewHabitCommitment,
  }) async {
    final id = await db.habitDao.createHabit(
      userId: _userId,
      title: title,
      today: chosenOn,
      now: now,
      firstCommitment: commitment,
    );
    if (clockTime != null) {
      await setClockTime(id, clockTime, chosenOn: chosenOn);
    }
    return id;
  }

  test('a Habit is notified only on the days it is due', () async {
    await createHabit(
      title: 'Stretch',
      commitment: const HabitCommitmentDraft(
        repeatKind: HabitRepeatKind.chosenWeekdays,
        chosenWeekdays: [1, 3, 5],
      ),
    );
    await settle();

    expect(os.days, ['2026-11-20', '2026-11-23', '2026-11-25']);
  });

  test('an anchor that is not a clock time withdraws the notification',
      () async {
    final id = await createHabit(title: 'Stretch');
    await settle();
    expect(os.pending, isNotEmpty);

    await db.habitDao.setAnchor(
      habitId: id,
      userId: _userId,
      today: '2026-11-20',
      now: now,
      kind: HabitAnchorKind.partOfDay,
      partOfDay: 'morning',
    );
    await settle();

    expect(os.pending, isEmpty);
  });

  test('editing the clock time re-arms the notification', () async {
    final id = await createHabit(title: 'Stretch');
    await settle();
    final before = os.pending.values.first;
    expect(parseHabitNotificationPayload(before)!.atMillis, isNot(0));

    await setClockTime(id, '09:00');
    await settle();

    final after = os.pending.values.first;
    final payload = parseHabitNotificationPayload(after)!;
    final fireAt = tz.TZDateTime.from(
        DateTime.fromMillisecondsSinceEpoch(payload.atMillis), kolkata);
    expect(fireAt.hour, 9);
    expect(fireAt.minute, 0);
  });

  test('a pause with an end date arms the days after it', () async {
    final id = await createHabit(title: 'Stretch');
    await settle();
    expect(os.days, hasLength(7));

    await db.habitDao.pause(
      habitId: id,
      userId: _userId,
      today: '2026-11-20',
      now: now,
      resumesOn: '2026-11-23',
    );
    await settle();

    expect(os.days, ['2026-11-23', '2026-11-24', '2026-11-25', '2026-11-26']);
  });

  test('resuming, archiving and restoring each change the pending set',
      () async {
    final id = await createHabit(title: 'Stretch');
    await settle();
    expect(os.pending, hasLength(7));

    await db.habitDao.pause(
      habitId: id,
      userId: _userId,
      today: '2026-11-20',
      now: now,
    );
    await settle();
    expect(os.pending, isEmpty);

    await db.habitDao.resume(
      habitId: id,
      userId: _userId,
      today: '2026-11-20',
      now: now,
    );
    await settle();
    expect(os.pending, hasLength(7));

    await db.habitDao.archive(
      habitId: id,
      userId: _userId,
      today: '2026-11-20',
      now: now,
    );
    await settle();
    expect(os.pending, isEmpty);

    await db.habitDao.restore(
      habitId: id,
      userId: _userId,
      today: '2026-11-20',
      now: now,
    );
    await settle();
    expect(os.pending, hasLength(7));
  });

  test('a Check-in withdraws the day it is for', () async {
    final id = await createHabit(title: 'Stretch');
    await settle();
    expect(os.days, contains('2026-11-20'));

    await db.habitDao.addCheckIn(
      habitId: id,
      userId: _userId,
      countsForDay: '2026-11-20',
      now: now,
    );
    await settle();

    expect(os.days, isNot(contains('2026-11-20')));
    expect(os.days, contains('2026-11-21'));
  });

  test('a stack names its Habits in order', () async {
    final stretch = await createHabit(title: 'Stretch');
    // The followers carry no time of their own: they follow the Habit
    // before them in the stack.
    final water = await createHabit(title: 'Water', clockTime: null);
    final journal = await createHabit(title: 'Journal', clockTime: null);
    await db.habitDao.setAnchor(
      habitId: water,
      userId: _userId,
      today: '2026-11-20',
      now: now,
      kind: HabitAnchorKind.afterHabit,
      anchorHabitId: stretch,
    );
    await db.habitDao.setAnchor(
      habitId: journal,
      userId: _userId,
      today: '2026-11-20',
      now: now,
      kind: HabitAnchorKind.afterHabit,
      anchorHabitId: water,
    );
    await settle();

    // One notification for the stack a day, naming its three Habits in order.
    expect(os.pending, hasLength(7));
    expect(os.titles.values.toSet(), {'Stretch, then Water, then Journal'});
  });

  test('a restart neither duplicates nor loses the notifications', () async {
    await createHabit(title: 'Stretch');
    await settle();
    final before = os.pending.length;

    // The app closes and opens again: a new container over the same
    // database, the OS keeping what it holds.
    container.dispose();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        notificationServiceProvider.overrideWithValue(os),
        clockProvider.overrideWithValue(() => now),
      ],
    );
    container.read(habitNotificationReconcilerProvider);
    await settle();

    expect(os.pending, hasLength(before));

    // The OS lost everything (a task killer cleared the app's alarms): the
    // next reconciliation arms it all again.
    os.pending.clear();
    await container.read(habitNotificationReconcilerProvider)?.onResumed();
    await settle();
    expect(os.pending, hasLength(before));
  });

  test('the notification moves with the device time zone', () async {
    await createHabit(title: 'Stretch');
    await settle();

    os.deviceZone = 'America/Los_Angeles';
    await container.read(habitNotificationReconcilerProvider)?.onResumed();
    await settle();

    for (final payload in os.pending.values) {
      final parsed = parseHabitNotificationPayload(payload)!;
      final fireAt = tz.TZDateTime.from(
          DateTime.fromMillisecondsSinceEpoch(parsed.atMillis), tz.local);
      expect(fireAt.hour, 7);
      expect(fireAt.minute, 0);
    }
  });
}
