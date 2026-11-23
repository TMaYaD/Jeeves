/// The habit notification reconciler: the OS's pending and delivered
/// notifications follow the plan.
///
/// The OS is a fake that keeps its pending set in memory, so these tests
/// prove what the app asks of the notification service, not Android's alarm
/// delivery.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'package:jeeves/database/gtd_database.dart'
    show Habit, HabitCheckIn, HabitInactivePeriod;
import 'package:jeeves/models/habit_commitment.dart';
import 'package:jeeves/models/habit_progress.dart';
import 'package:jeeves/services/habit_notifications.dart';
import 'package:jeeves/services/notification_service.dart';

var _sequence = 0;

Habit habit({
  required String id,
  String title = 'Habit',
  String anchorKind = 'clock_time',
  String? anchorClockTime = '07:00',
  int? timeEstimateMinutes,
}) =>
    Habit(
      id: id,
      userId: 'user-1',
      title: title,
      timeEstimateMinutes: timeEstimateMinutes,
      anchorKind: anchorKind,
      anchorClockTime: anchorClockTime,
      createdAt: '2026-11-02T09:00:00.000Z',
    );

HabitCommitment commitment({
  required String habitId,
  String chosenOn = '2026-11-02',
  HabitRepeatKind repeatKind = HabitRepeatKind.everyDay,
}) =>
    HabitCommitment(
      id: 'c-${_sequence++}',
      habitId: habitId,
      chosenOn: chosenOn,
      createdAt: DateTime.utc(2026, 11, 2, 9, 0, _sequence),
      repeatKind: repeatKind,
    );

HabitInactivePeriod inactive(
  String habitId,
  String kind,
  String startsOn, {
  String? endsBefore,
}) =>
    HabitInactivePeriod(
      id: 'ip-${_sequence++}',
      userId: 'user-1',
      habitId: habitId,
      kind: kind,
      startsOn: startsOn,
      endsBefore: endsBefore,
    );

/// The OS, stood in for: keeps its pending set and its tray in memory.
class FakeOsNotifications extends NotificationService {
  FakeOsNotifications() : super.forTesting();

  /// The alarms the OS holds, by notification id.
  final pending = <int, String>{};

  /// The notifications that already fired and sit in the tray.
  final delivered = <int>{};

  /// Every schedule call, in order.
  final scheduled = <int>[];

  /// Every cancel call, in order.
  final cancelled = <int>[];

  /// Ids the OS refuses to arm.
  final refused = <int>{};

  /// The device's time zone, read on the next resume.
  String? deviceZone;

  @override
  Future<void> scheduleHabitNotification({
    required int id,
    required String title,
    required String body,
    required DateTime fireAt,
    required String payload,
    HabitNotificationAction action = HabitNotificationAction.none,
  }) async {
    if (refused.contains(id)) {
      throw StateError('The OS refused notification $id.');
    }
    scheduled.add(id);
    pending[id] = payload;
  }

  @override
  Future<void> cancelReminder(int id) async {
    cancelled.add(id);
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

void main() {
  setUpAll(tz_data.initializeTimeZones);

  late tz.Location kolkata;
  late FakeOsNotifications os;
  late StreamController<List<HabitHistory>> histories;
  late HabitNotificationReconciler reconciler;
  var now = DateTime.utc(2026, 11, 20, 1); // 06:30 in Kolkata.

  setUp(() {
    now = DateTime.utc(2026, 11, 20, 1); // 06:30 in Kolkata.
    kolkata = tz.getLocation('Asia/Kolkata');
    tz.setLocalLocation(kolkata);
    os = FakeOsNotifications()..deviceZone = 'Asia/Kolkata';
    histories = StreamController<List<HabitHistory>>();
    reconciler = HabitNotificationReconciler(
      notifications: os,
      histories: histories.stream,
      location: () => kolkata,
      now: () => now,
    )..start(listenToLifecycle: false);
  });

  tearDown(() async {
    reconciler.dispose();
    await histories.close();
  });

  /// Lets the reconciler finish its pass.
  Future<void> settle() async {
    await pumpEventQueue();
    await reconciler.settled();
  }

  Future<void> emit(List<HabitHistory> value) async {
    histories.add(value);
    await settle();
  }

  HabitHistory oneHabit({String id = 'h1', String? clockTime = '07:00'}) =>
      HabitHistory(
        habit: habit(id: id, anchorClockTime: clockTime),
        commitments: [commitment(habitId: id)],
      );

  test('the first run schedules every upcoming notification', () async {
    await emit([oneHabit()]);

    // Seven days of horizon, today's still ahead.
    expect(os.pending, hasLength(7));
    expect(os.scheduled, hasLength(7));
  });

  test('a second identical run schedules nothing', () async {
    await emit([oneHabit()]);
    final before = os.scheduled.length;

    await emit([oneHabit()]);

    expect(os.scheduled, hasLength(before));
  });

  test('a Habit that is no longer for the day is cancelled', () async {
    await emit([oneHabit()]);
    final todayId = os.pending.keys.firstWhere((id) =>
        parseHabitNotificationPayload(os.pending[id])!.day == '2026-11-20');

    // The Habit is checked in: today is no longer for it.
    await emit([
      HabitHistory(
        habit: habit(id: 'h1'),
        commitments: [commitment(habitId: 'h1')],
        checkIns: [
          HabitCheckIn(
            id: 'ci-1',
            userId: 'user-1',
            habitId: 'h1',
            countsForDay: '2026-11-20',
            checkedInAt: '2026-11-20T06:00:00.000Z',
          )
        ],
      ),
    ]);

    expect(os.pending.containsKey(todayId), isFalse);
    expect(os.cancelled, contains(todayId));
  });

  test('a pending notification whose time has passed survives', () async {
    await emit([oneHabit()]);
    final todayId = os.pending.keys.firstWhere((id) =>
        parseHabitNotificationPayload(os.pending[id])!.day == '2026-11-20');

    // 08:00 in Kolkata: today's 07:00 has passed, and the OS has not
    // delivered the alarm yet.
    now = DateTime.utc(2026, 11, 20, 2, 30);
    await reconciler.onResumed();
    await settle();

    expect(os.pending.containsKey(todayId), isTrue);
    expect(os.cancelled, isNot(contains(todayId)));
  });

  test('a tray entry that is still planned stays, and one that is not goes',
      () async {
    await emit([oneHabit()]);
    final ids = os.pending.keys.toList();
    final todayId = ids.firstWhere((id) =>
        parseHabitNotificationPayload(os.pending[id])!.day == '2026-11-20');
    final tomorrowId = ids.firstWhere((id) =>
        parseHabitNotificationPayload(os.pending[id])!.day == '2026-11-21');

    // Today's alarm fires and sits in the tray.
    os.pending.remove(todayId);
    os.delivered.add(todayId);
    // A tray entry from a Habit that is no longer for today.
    os.delivered.add(9999);

    await reconciler.onResumed();
    await settle();

    expect(os.delivered, contains(todayId));
    expect(os.delivered, isNot(contains(9999)));
    expect(os.pending.containsKey(tomorrowId), isTrue);
  });

  test('a timezone change on resume re-schedules everything', () async {
    await emit([oneHabit()]);
    final before = os.scheduled.length;

    os.deviceZone = 'America/Los_Angeles';
    await reconciler.onResumed();
    await settle();

    expect(os.scheduled.length, greaterThan(before));
  });

  test('one refused alarm does not stop the rest', () async {
    final histories2 = [
      HabitHistory(
        habit: habit(id: 'h1', anchorClockTime: '07:00'),
        commitments: [commitment(habitId: 'h1')],
      ),
      HabitHistory(
        habit: habit(id: 'h2', anchorClockTime: '08:00'),
        commitments: [commitment(habitId: 'h2')],
      ),
    ];
    final refusedId = habitNotificationId('h1', '2026-11-20');
    os.refused.add(refusedId);

    await emit(histories2);

    // The other Habit's alarms are armed.
    expect(os.pending, isNotEmpty);
    expect(os.pending.containsKey(refusedId), isFalse);
    expect(os.pending.containsKey(habitNotificationId('h2', '2026-11-20')),
        isTrue);
  });
}
