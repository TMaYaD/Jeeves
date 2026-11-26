/// Journey: a Habit's clock time drives a notification on the days it is for,
/// through the real database and the real write paths.
///
/// The OS is replaced by [FakeHabitNotifications], which keeps its pending set in
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

void main() {
  setUpAll(() {
    configureSqliteForTests();
    TestWidgetsFlutterBinding.ensureInitialized();
    tz_data.initializeTimeZones();
  });

  late tz.Location kolkata;
  late GtdDatabase db;
  late FakeHabitNotifications os;
  late ProviderContainer container;
  // Friday 20 November 2026, 06:30 local — before the 07:00 a clock-time
  // Habit notifies at.
  var now = DateTime.utc(2026, 11, 20, 1);

  setUp(() {
    kolkata = tz.getLocation('Asia/Kolkata');
    tz.setLocalLocation(kolkata);
    db = GtdDatabase(NativeDatabase.memory());
    os = FakeHabitNotifications()..deviceZone = 'Asia/Kolkata';
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
  /// notify. A null [clockTime] leaves the Habit without one. An
  /// [estimateMinutes] makes it a binary Habit with an estimate, whose
  /// notification carries a Start Focus button.
  Future<String> createHabit({
    required String title,
    String chosenOn = '2026-11-20',
    String? clockTime = '07:00',
    int? estimateMinutes,
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
    if (estimateMinutes != null) {
      await db.habitDao.updateHabitDetails(
        habitId: id,
        userId: _userId,
        title: title,
        notes: null,
        energyLevel: null,
        timeEstimateMinutes: estimateMinutes,
        now: now,
      );
    }
    return id;
  }

  /// The id of the notification the OS holds for [habitId].
  int notificationIdFor(String habitId) => os.pending.entries
      .firstWhere((entry) =>
          parseHabitNotificationPayload(entry.value)!.habitId == habitId)
      .key;

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

  test('a binary Habit with an estimate is scheduled with Start Focus',
      () async {
    final id = await createHabit(title: 'Stretch', estimateMinutes: 20);
    await settle();

    final notificationId = notificationIdFor(id);
    expect(os.actions[notificationId], HabitNotificationAction.startFocus);
    expect(os.buttons[notificationId], 'Start Focus');
  });

  test('a measurable Habit is scheduled with no button', () async {
    final id = await createHabit(
      title: 'Water',
      commitment: const HabitCommitmentDraft(
        repeatKind: HabitRepeatKind.everyDay,
        unitLabel: 'glasses',
        dailyTargetAmount: 8,
      ),
    );
    await settle();

    final notificationId = notificationIdFor(id);
    expect(os.actions[notificationId], HabitNotificationAction.none);
    expect(os.buttons[notificationId], isNull);
  });

  test('an alarm armed before the button existed gets the button', () async {
    final id = await createHabit(title: 'Stretch', estimateMinutes: 20);
    await settle();

    final notificationId = notificationIdFor(id);
    // The alarm an older build armed: Start Focus had no button then, and
    // the payload said so. The rest of the payload is the same, so the
    // reconciler re-arms it only because the button changed.
    final armed = os.pending[notificationId]!;
    os.pending[notificationId] =
        armed.replaceFirst('|action=startfocus', '|action=focus');
    expect(os.pending[notificationId], isNot(armed));
    os.buttons.remove(notificationId);

    await container.read(habitNotificationReconcilerProvider)?.onResumed();
    await settle();

    expect(os.pending[notificationId], contains('|action=startfocus'));
    expect(os.buttons[notificationId], 'Start Focus');
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
