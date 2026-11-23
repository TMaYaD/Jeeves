/// The habit notification planner: which days a Habit is for, what a stack's
/// notification says, and when it fires.
///
/// Pure: the Habit histories are hand-built, so nothing here reads the
/// database or the clock.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'package:jeeves/database/gtd_database.dart'
    show Habit, HabitCheckIn, HabitInactivePeriod;
import 'package:jeeves/models/habit_commitment.dart';
import 'package:jeeves/models/habit_progress.dart';
import 'package:jeeves/services/habit_notifications.dart';

var _sequence = 0;

/// A Habit row. The anchor and the estimate are what the planner reads.
Habit habit({
  required String id,
  String title = 'Habit',
  String anchorKind = 'clock_time',
  String? anchorClockTime = '07:00',
  String? anchorHabitId,
  int? timeEstimateMinutes,
  String createdAt = '2026-11-02T09:00:00.000Z',
}) =>
    Habit(
      id: id,
      userId: 'user-1',
      title: title,
      timeEstimateMinutes: timeEstimateMinutes,
      anchorKind: anchorKind,
      anchorClockTime: anchorClockTime,
      anchorHabitId: anchorHabitId,
      createdAt: createdAt,
    );

HabitCommitment commitment({
  required String habitId,
  String id = 'c1',
  String chosenOn = '2026-11-02',
  HabitRepeatKind repeatKind = HabitRepeatKind.everyDay,
  List<int>? chosenWeekdays,
  int? timesPerPeriod,
  String? unitLabel,
  double? dailyTargetAmount,
}) =>
    HabitCommitment(
      id: id,
      habitId: habitId,
      chosenOn: chosenOn,
      createdAt: DateTime.utc(2026, 11, 2, 9, 0, _sequence++),
      repeatKind: repeatKind,
      chosenWeekdays: chosenWeekdays,
      timesPerPeriod: timesPerPeriod,
      unitLabel: unitLabel,
      dailyTargetAmount: dailyTargetAmount,
    );

HabitCheckIn checkIn(String habitId, String day) => HabitCheckIn(
      id: 'ci-${_sequence++}',
      userId: 'user-1',
      habitId: habitId,
      countsForDay: day,
      checkedInAt: '${day}T12:00:00.000Z',
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

/// Monday 16 November 2026 is a week start; Friday the 20th is "today" in
/// these tests.
const _today = '2026-11-20';

/// 06:30 local on Friday 20 November 2026 in Kolkata: before the 07:00 a
/// clock-time Habit notifies at, so "today" is still ahead.
final _now = DateTime.utc(2026, 11, 20, 1);

List<String> _daysOf(List<PlannedHabitNotification> planned) =>
    [for (final entry in planned) entry.day];

void main() {
  setUpAll(tz_data.initializeTimeZones);

  late tz.Location kolkata;
  setUp(() {
    kolkata = tz.getLocation('Asia/Kolkata');
    tz.setLocalLocation(kolkata);
  });

  ({List<PlannedHabitNotification> upcoming, List<PlannedHabitNotification> passedToday})
      planOf(
    List<HabitHistory> histories, {
    tz.Location? location,
    DateTime? now,
    int horizonDays = 7,
    int maxScheduled = 200,
  }) =>
          planHabitNotifications(
            histories: histories,
            now: now ?? _now,
            location: location ?? kolkata,
            horizonDays: horizonDays,
            maxScheduled: maxScheduled,
          );

  group('which days a Habit is for', () {
    test('a chosen-weekdays Habit is planned only on its days', () {
      final history = HabitHistory(
        habit: habit(id: 'h1'),
        commitments: [
          commitment(
            habitId: 'h1',
            repeatKind: HabitRepeatKind.chosenWeekdays,
            // Monday, Wednesday, Friday.
            chosenWeekdays: [1, 3, 5],
          ),
        ],
      );

      final plan = planOf([history]);

      expect(_daysOf(plan.upcoming), ['2026-11-20', '2026-11-23', '2026-11-25']);
    });

    test('part-of-day, no anchor and after-Habit anchors plan nothing', () {
      final plans = [
        habit(id: 'p1', anchorKind: 'part_of_day', anchorClockTime: null),
        habit(id: 'p2', anchorKind: 'none', anchorClockTime: null),
        habit(id: 'p3', anchorKind: 'after_habit', anchorClockTime: null,
            anchorHabitId: 'p1'),
      ];
      final histories = [
        for (final row in plans)
          HabitHistory(
            habit: row,
            commitments: [commitment(habitId: row.id)],
          ),
      ];

      expect(planOf(histories).upcoming, isEmpty);
    });

    test('a Habit is not planned before its commitment starts', () {
      final history = HabitHistory(
        habit: habit(id: 'h1'),
        commitments: [
          commitment(
            habitId: 'h1',
            chosenOn: '2026-11-24',
            repeatKind: HabitRepeatKind.chosenWeekdays,
            chosenWeekdays: [1, 2, 3, 4, 5, 6, 7],
          ),
        ],
      );

      final plan = planOf([history]);

      expect(_daysOf(plan.upcoming), ['2026-11-24', '2026-11-25', '2026-11-26']);
    });

    test('a three-per-week Habit notifies every day until N is met', () {
      final history = HabitHistory(
        habit: habit(id: 'h1'),
        commitments: [
          commitment(
            habitId: 'h1',
            repeatKind: HabitRepeatKind.timesPerWeek,
            timesPerPeriod: 3,
          ),
        ],
      );

      // Nothing done yet: every day of the horizon is still open.
      expect(_daysOf(planOf([history]).upcoming), hasLength(7));

      // One Check-in: still below N, so the days still notify.
      final withOne = HabitHistory(
        habit: history.habit,
        commitments: history.commitments,
        checkIns: [checkIn('h1', '2026-11-19')],
      );
      expect(_daysOf(planOf([withOne]).upcoming), hasLength(7));
    });

    test('a met period stops the notifications for the rest of the week', () {
      final history = HabitHistory(
        habit: habit(id: 'h1'),
        commitments: [
          commitment(
            habitId: 'h1',
            repeatKind: HabitRepeatKind.timesPerWeek,
            timesPerPeriod: 3,
          ),
        ],
        checkIns: [
          checkIn('h1', '2026-11-16'),
          checkIn('h1', '2026-11-17'),
          checkIn('h1', '2026-11-18'),
        ],
      );

      final plan = planOf([history]);

      // This week is met; next Monday opens a new one.
      expect(_daysOf(plan.upcoming), ['2026-11-23', '2026-11-24', '2026-11-25',
        '2026-11-26']);
    });
  });

  group('stacks', () {
    test('a stack is titled with its Habits in order and armed at the first',
        () {
      final histories = [
        HabitHistory(
          habit: habit(id: 'h1', title: 'Stretch'),
          commitments: [commitment(habitId: 'h1')],
        ),
        HabitHistory(
          habit: habit(
              id: 'h2',
              title: 'Water',
              anchorKind: 'after_habit',
              anchorClockTime: null,
              anchorHabitId: 'h1'),
          commitments: [commitment(habitId: 'h2')],
        ),
        HabitHistory(
          habit: habit(
              id: 'h3',
              title: 'Journal',
              anchorKind: 'after_habit',
              anchorClockTime: null,
              anchorHabitId: 'h2'),
          commitments: [commitment(habitId: 'h3')],
        ),
      ];

      final plan = planOf(histories);

      expect(plan.upcoming.first.title, 'Stretch, then Water, then Journal');
      expect(plan.upcoming.first.namedHabitIds, ['h1', 'h2', 'h3']);
      expect(
        plan.upcoming.first.fireAt
            .isAtSameMomentAs(tz.TZDateTime(kolkata, 2026, 11, 20, 7)),
        isTrue,
      );
    });

    test('a member that is not due that day is left out', () {
      final histories = [
        HabitHistory(
          habit: habit(id: 'h1', title: 'Stretch'),
          commitments: [commitment(habitId: 'h1')],
        ),
        HabitHistory(
          habit: habit(
              id: 'h2',
              title: 'Water',
              anchorKind: 'after_habit',
              anchorClockTime: null,
              anchorHabitId: 'h1'),
          commitments: [
            commitment(
              habitId: 'h2',
              repeatKind: HabitRepeatKind.chosenWeekdays,
              chosenWeekdays: [1, 3, 5],
            ),
          ],
        ),
      ];

      final plan = planOf(histories);

      // Tuesday the 24th: Water is not due then, Stretch is.
      final tuesday = plan.upcoming.firstWhere((e) => e.day == '2026-11-24');
      expect(tuesday.namedHabitIds, ['h1']);
      expect(tuesday.title, 'Stretch');
      // Friday the 20th: both are for that day.
      final friday = plan.upcoming.firstWhere((e) => e.day == '2026-11-20');
      expect(friday.namedHabitIds, ['h1', 'h2']);
    });

    test('a paused clock-time Habit takes its followers with it', () {
      final histories = [
        HabitHistory(
          habit: habit(id: 'h1', title: 'Stretch'),
          commitments: [commitment(habitId: 'h1')],
          inactivePeriods: [
            inactive('h1', 'paused', '2026-11-19', endsBefore: '2026-11-27')
          ],
        ),
        HabitHistory(
          habit: habit(
              id: 'h2',
              title: 'Water',
              anchorKind: 'after_habit',
              anchorClockTime: null,
              anchorHabitId: 'h1'),
          commitments: [commitment(habitId: 'h2')],
        ),
      ];

      final plan = planOf(histories);

      expect(plan.upcoming, isEmpty);
    });
  });

  group('pauses and archives', () {
    test('a paused Habit plans nothing', () {
      final history = HabitHistory(
        habit: habit(id: 'h1'),
        commitments: [commitment(habitId: 'h1')],
        inactivePeriods: [inactive('h1', 'paused', '2026-11-19')],
      );

      expect(planOf([history]).upcoming, isEmpty);
    });

    test('a pause that ends in three days is planned from that day', () {
      final history = HabitHistory(
        habit: habit(id: 'h1'),
        commitments: [commitment(habitId: 'h1')],
        inactivePeriods: [
          inactive('h1', 'paused', '2026-11-19', endsBefore: '2026-11-23')
        ],
      );

      final plan = planOf([history]);

      expect(_daysOf(plan.upcoming),
          ['2026-11-23', '2026-11-24', '2026-11-25', '2026-11-26']);
    });

    test('an archived Habit plans nothing', () {
      final history = HabitHistory(
        habit: habit(id: 'h1'),
        commitments: [commitment(habitId: 'h1')],
        inactivePeriods: [inactive('h1', 'archived', '2026-11-18')],
      );

      expect(planOf([history]).upcoming, isEmpty);
    });
  });

  group('what the notification says', () {
    test('a binary Habit offers Check in', () {
      final history = HabitHistory(
        habit: habit(id: 'h1', title: 'Stretch'),
        commitments: [commitment(habitId: 'h1')],
      );

      final entry = planOf([history]).upcoming.first;

      expect(entry.action, HabitNotificationAction.checkIn);
      expect(entry.title, 'Stretch');
      expect(entry.body, 'Time for it.');
    });

    test('a binary Habit with an estimate offers Start Focus', () {
      final history = HabitHistory(
        habit: habit(id: 'h1', title: 'Stretch', timeEstimateMinutes: 15),
        commitments: [commitment(habitId: 'h1')],
      );

      final entry = planOf([history]).upcoming.first;

      expect(entry.action, HabitNotificationAction.startFocus);
      expect(entry.body, '15 min — start when you\'re ready.');
    });

    test('a measurable Habit has no button and says its target', () {
      final history = HabitHistory(
        habit: habit(id: 'h1', title: 'Water'),
        commitments: [
          commitment(
            habitId: 'h1',
            unitLabel: 'glasses',
            dailyTargetAmount: 8,
          ),
        ],
      );

      final entry = planOf([history]).upcoming.first;

      expect(entry.action, HabitNotificationAction.none);
      expect(entry.body, 'Target: 8 glasses');
    });

    test('the button follows the first Habit a stack names', () {
      final histories = [
        HabitHistory(
          habit: habit(id: 'h1', title: 'Stretch'),
          commitments: [commitment(habitId: 'h1')],
        ),
        HabitHistory(
          habit: habit(
              id: 'h2',
              title: 'Water',
              anchorKind: 'after_habit',
              anchorClockTime: null,
              anchorHabitId: 'h1',
              timeEstimateMinutes: 10),
          commitments: [commitment(habitId: 'h2')],
        ),
      ];

      final entry = planOf(histories).upcoming.first;

      expect(entry.firstHabitId, 'h1');
      expect(entry.action, HabitNotificationAction.checkIn);
    });
  });

  group('the plan', () {
    test('a Check-in today withdraws today and leaves tomorrow', () {
      final history = HabitHistory(
        habit: habit(id: 'h1'),
        commitments: [commitment(habitId: 'h1')],
        checkIns: [checkIn('h1', _today)],
      );

      final plan = planOf([history]);

      expect(_daysOf(plan.upcoming).first, '2026-11-21');
      expect(plan.passedToday, isEmpty);
    });

    test("today's time that has passed is reported apart, not re-armed", () {
      final history = HabitHistory(
        habit: habit(id: 'h1'),
        commitments: [commitment(habitId: 'h1')],
      );

      // 08:00 in Kolkata is past 07:00, so today's entry has fired.
      final plan = planOf([history], now: DateTime.utc(2026, 11, 20, 2, 30));

      expect(plan.passedToday, hasLength(1));
      expect(plan.passedToday.first.day, _today);
      expect(_daysOf(plan.upcoming).first, '2026-11-21');
    });

    test('the cap keeps the soonest', () {
      final histories = [
        for (var i = 0; i < 10; i++)
          HabitHistory(
            habit: habit(id: 'h$i', anchorClockTime: '0${i + 7}:00'),
            commitments: [commitment(habitId: 'h$i')],
          ),
      ];

      final plan = planOf(histories, maxScheduled: 3);

      expect(plan.upcoming, hasLength(3));
      expect(
        [for (final entry in plan.upcoming) entry.fireAt.hour],
        [7, 8, 9],
      );
    });

    test('a payload round-trips', () {
      final history = HabitHistory(
        habit: habit(id: 'h1', title: 'Stretch'),
        commitments: [commitment(habitId: 'h1')],
      );

      final entry = planOf([history]).upcoming.first;
      final payload = parseHabitNotificationPayload(entry.payload);

      expect(payload, isNotNull);
      expect(payload!.habitId, 'h1');
      expect(payload.stackHabitId, 'h1');
      expect(payload.day, entry.day);
      expect(payload.atMillis, entry.fireAt.millisecondsSinceEpoch);
      expect(payload.action, HabitNotificationAction.checkIn);
      expect(payload.signature,
          habitNotificationSignature(entry.title, entry.body));
    });

    test('a stack that names other Habits has another payload', () {
      final withFollower = [
        HabitHistory(
          habit: habit(id: 'h1', title: 'Stretch'),
          commitments: [commitment(habitId: 'h1')],
        ),
        HabitHistory(
          habit: habit(
              id: 'h2',
              title: 'Water',
              anchorKind: 'after_habit',
              anchorClockTime: null,
              anchorHabitId: 'h1'),
          commitments: [
            commitment(
              habitId: 'h2',
              repeatKind: HabitRepeatKind.chosenWeekdays,
              chosenWeekdays: [1, 3, 5],
            ),
          ],
        ),
      ];
      final withoutFollower = [
        withFollower.first,
        HabitHistory(
          habit: withFollower[1].habit,
          commitments: [
            commitment(
              habitId: 'h2',
              repeatKind: HabitRepeatKind.chosenWeekdays,
              chosenWeekdays: [2, 4, 6],
            ),
          ],
        ),
      ];

      // Friday the 20th: the follower is due in one plan and not in the
      // other, so the two notifications say different things.
      PlannedHabitNotification friday(List<PlannedHabitNotification> planned) =>
          planned.firstWhere((e) => e.day == '2026-11-20');

      final named = friday(planOf(withFollower).upcoming);
      final alone = friday(planOf(withoutFollower).upcoming);

      expect(named.namedHabitIds, ['h1', 'h2']);
      expect(alone.namedHabitIds, ['h1']);
      expect(named.payload, isNot(alone.payload));
      expect(named.signature, isNot(alone.signature));
    });

    test('a payload that is not a habit payload reads as nothing', () {
      expect(parseHabitNotificationPayload('outcome:abc'), isNull);
      expect(parseHabitNotificationPayload(null), isNull);
    });
  });

  group('the device time zone', () {
    test('the wall-clock time moves with the zone', () {
      final history = HabitHistory(
        habit: habit(id: 'h1', anchorClockTime: '07:00'),
        commitments: [commitment(habitId: 'h1')],
      );

      final kolkataPlan = planOf([history]);
      final laPlan = planOf([history], location: tz.getLocation('America/Los_Angeles'));

      expect(
        kolkataPlan.upcoming.first.fireAt
            .isAtSameMomentAs(tz.TZDateTime(kolkata, 2026, 11, 20, 7)),
        isTrue,
      );
      // In Los Angeles the instant is still the evening of the 19th, so
      // "today" there is the 19th and the 07:00 of that day has passed.
      final losAngeles = tz.getLocation('America/Los_Angeles');
      expect(laPlan.passedToday.first.day, '2026-11-19');
      expect(
        laPlan.upcoming.first.fireAt
            .isAtSameMomentAs(tz.TZDateTime(losAngeles, 2026, 11, 20, 7)),
        isTrue,
      );
    });

    test('a clock time in a DST gap moves forward', () {
      final newYork = tz.getLocation('America/New_York');
      // 02:30 on 8 March 2026 does not exist in New York.
      final history = HabitHistory(
        habit: habit(id: 'h1', anchorClockTime: '02:30'),
        commitments: [commitment(habitId: 'h1', chosenOn: '2026-03-01')],
      );

      final plan = planOf(
        [history],
        location: newYork,
        now: DateTime.utc(2026, 3, 6, 12),
      );

      final entry = plan.upcoming.firstWhere((e) => e.day == '2026-03-08');
      expect(entry.fireAt.hour, isNot(2));
      expect(entry.fireAt.isAtSameMomentAs(tz.TZDateTime(newYork, 2026, 3, 8, 3, 30)),
          isTrue);
    });
  });
}
