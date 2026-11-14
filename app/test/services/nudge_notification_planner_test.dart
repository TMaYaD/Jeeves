import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/nudge_predicates.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:jeeves/services/nudge_notification_scheduler.dart';

/// The planner is a pure function of an instant and frozen facts. Reference day
/// is Wednesday 11 Nov 2026; planning 08:00, shutdown 18:00, Weekly Review
/// 09:00 unless a test says otherwise.
DateTime _at(int dayOffset, int hour, [int minute = 0]) =>
    DateTime(2026, 11, 11 + dayOffset, hour, minute);

/// Weekly Review's notifications are off unless a test turns them on: it falls
/// due inside the seven-day horizon by default and, from then on, outranks
/// Daily Planning at every instant after its Trigger edge.
const _withoutWeeklyReview = {
  RitualId.dailyPlanning: true,
  RitualId.eveningShutdown: true,
  RitualId.weeklyReview: false,
};
const _allEnabled = {
  RitualId.dailyPlanning: true,
  RitualId.eveningShutdown: true,
  RitualId.weeklyReview: true,
};

NudgeNotificationFacts _facts({
  DateTime? now,
  int planningHour = 8,
  int shutdownHour = 18,
  int weeklyReviewHour = 9,
  Map<RitualId, bool> enabled = _withoutWeeklyReview,
  Map<RitualId, NudgeState> nudgeState = const {},
  Set<RitualId> inProgress = const {},
  bool hasAnyItem = true,
  bool hasInboxOrNext = true,
  DateTime? latestSessionStartedAt,
  bool sessionIsOpen = false,
  // Not due by default.
  DateTime? weeklyReviewLastCompleted,
  Map<RitualId, int> snoozeMinutes = const {},
}) {
  final instant = now ?? _at(0, 7);
  return NudgeNotificationFacts(
    now: instant,
    notificationEnabled: enabled,
    nudgeState: nudgeState,
    inProgress: inProgress,
    dpr: DprFacts(
      planningHour: planningHour,
      planningMinute: 0,
      shutdownHour: shutdownHour,
      shutdownMinute: 0,
      hasAnyItem: hasAnyItem,
      hasInboxOrNext: hasInboxOrNext,
      latestSessionStartedAt: latestSessionStartedAt,
    ),
    es: EsFacts(
      shutdownHour: shutdownHour,
      shutdownMinute: 0,
      sessionIsOpen: sessionIsOpen,
    ),
    wr: WrFacts(
      dueAt: hasAnyItem
          ? (weeklyReviewLastCompleted ??
                  instant.subtract(const Duration(days: 2)))
              .add(const Duration(days: 7))
          : null,
    ),
    weeklyReviewHour: weeklyReviewHour,
    weeklyReviewMinute: 0,
    snoozeMinutes: snoozeMinutes,
  );
}

Iterable<PlannedNudgeNotification> _of(
        List<PlannedNudgeNotification> plan, RitualId ritual) =>
    plan.where((p) => p.ritual == ritual);

void main() {
  group('horizon', () {
    test('plans Daily Planning each day of the horizon, and nothing past it', () {
      final plan = planNudgeNotifications(_facts());

      final dpr = _of(plan, RitualId.dailyPlanning).toList();
      expect(dpr.map((p) => p.fireAt),
          [for (var d = 0; d < 7; d++) _at(d, 8)]);
      expect(plan.every((p) => p.fireAt.isBefore(_at(7, 0))), isTrue,
          reason: 'no alarm is planned past the 7-day horizon');
      expect(plan.length, 7, reason: 'ES has no open session, WR is off');
    });

    test('a Ritual with notifications off gets no alarms',
        () {
      final plan = planNudgeNotifications(_facts(enabled: const {
        RitualId.dailyPlanning: false,
        RitualId.eveningShutdown: true,
        RitualId.weeklyReview: true,
      }));

      expect(_of(plan, RitualId.dailyPlanning), isEmpty);
    });

    test('a time earlier today than now is not planned for today', () {
      final plan = planNudgeNotifications(_facts(now: _at(0, 8, 30)));

      expect(_of(plan, RitualId.dailyPlanning)
          .first.fireAt, _at(1, 8));
    });

    test('ids are stable between plans and stay below the due-date range', () {
      final first = planNudgeNotifications(_facts());
      final second = planNudgeNotifications(_facts());

      expect(first.map((p) => p.id), second.map((p) => p.id));
      expect(first.map((p) => p.id).toSet().length, first.length);
      expect(first.every((p) => p.id < 10000), isTrue);
    });

    test('the same calendar day keeps its id as the plan rolls forward', () {
      final morning = planNudgeNotifications(_facts());
      final nextDay = planNudgeNotifications(_facts(now: _at(1, 7)));

      int idOnDay(List<PlannedNudgeNotification> plan, int offset) => plan
          .firstWhere((p) => p.fireAt == _at(offset, 8))
          .id;
      expect(idOnDay(morning, 3), idOnDay(nextDay, 3));
    });
  });

  group('payload', () {
    test('carries the firing edge, snooze duration and fire instant', () {
      final plan = planNudgeNotifications(_facts(
        snoozeMinutes: const {RitualId.dailyPlanning: 15},
      ));

      final parsed = parseRitualNotificationPayload(plan.first.payload)!;
      expect(parsed.ritual, RitualId.dailyPlanning);
      expect(parsed.snoozeMinutes, 15);
      expect(parsed.edge!.isAtSameMomentAs(_at(0, 8)), isTrue);
      expect(parsed.fireAt, _at(0, 8));
    });

    test('a bare payload from an older build still resolves to its Ritual', () {
      final parsed = parseRitualNotificationPayload('nudge:shutdown')!;

      expect(parsed.ritual, RitualId.eveningShutdown);
      expect(parsed.edge, isNull);
      expect(parsed.snoozeMinutes, isNull);
      expect(ritualIdFromNotificationPayload('nudge:periodic_review'),
          RitualId.weeklyReview);
      expect(ritualIdFromNotificationPayload('focus'), isNull);
    });
  });

  group('precedence at a shared instant (Weekly Review > Shutdown > Planning)',
      () {
    final staleSession = _at(-1, 10); // started before the last 18:00 anchor

    test('Weekly Review beats Daily Planning', () {
      final plan = planNudgeNotifications(_facts(
        planningHour: 9,
        weeklyReviewLastCompleted: _at(-9, 7),
        enabled: _allEnabled,
      ));

      expect(_of(plan, RitualId.weeklyReview).first.fireAt, _at(0, 9));
      expect(_of(plan, RitualId.dailyPlanning), isEmpty,
          reason: 'DPR shares 09:00 with a due Weekly Review every day');
    });

    test('Weekly Review beats Evening Shutdown', () {
      final plan = planNudgeNotifications(_facts(
        shutdownHour: 9,
        sessionIsOpen: true,
        latestSessionStartedAt: _at(0, 6),
        weeklyReviewLastCompleted: _at(-9, 7),
        enabled: _allEnabled,
      ));

      expect(_of(plan, RitualId.weeklyReview), isNotEmpty);
      expect(_of(plan, RitualId.eveningShutdown), isEmpty);
    });

    test('Evening Shutdown beats Daily Planning on a stale open session', () {
      final plan = planNudgeNotifications(_facts(
        planningHour: 9,
        shutdownHour: 9,
        sessionIsOpen: true,
        latestSessionStartedAt: staleSession,
      ));

      expect(_of(plan, RitualId.eveningShutdown).first.fireAt, _at(0, 9));
      expect(_of(plan, RitualId.dailyPlanning), isEmpty);
    });

    test('the walk-down passes a Ritual with notifications off', () {
      final plan = planNudgeNotifications(_facts(
        planningHour: 9,
        weeklyReviewLastCompleted: _at(-9, 7),
        enabled: const {
          RitualId.dailyPlanning: true,
          RitualId.eveningShutdown: true,
          RitualId.weeklyReview: false,
        },
      ));

      expect(_of(plan, RitualId.weeklyReview), isEmpty);
      expect(_of(plan, RitualId.dailyPlanning).first.fireAt, _at(0, 9));
    });
  });

  group('the Ritual\'s own Nudge must be visible', () {
    test('Evening Shutdown does not notify with no open session', () {
      final plan = planNudgeNotifications(_facts());

      expect(_of(plan, RitualId.eveningShutdown), isEmpty);
    });

    test('Daily Planning does not notify with nothing to plan', () {
      final plan = planNudgeNotifications(
          _facts(hasInboxOrNext: false, hasAnyItem: false));

      expect(_of(plan, RitualId.dailyPlanning), isEmpty);
    });

    test('Daily Planning still notifies in the morning of a stale-session day',
        () {
      final plan = planNudgeNotifications(_facts(
        sessionIsOpen: true,
        latestSessionStartedAt: _at(-1, 10),
      ));

      expect(_of(plan, RitualId.dailyPlanning).first.fireAt, _at(0, 8),
          reason: 'Shutdown is not firing at 08:00, so Planning is the head');
      expect(_of(plan, RitualId.eveningShutdown).first.fireAt, _at(0, 18));
    });
  });

  group('dismiss, snooze and in-progress hygiene', () {
    test('a dismiss hides only the firing it covered', () {
      // Due since 10 Nov 07:00; while due, the Nudge refires every day.
      final plan = planNudgeNotifications(_facts(
        weeklyReviewLastCompleted: _at(-8, 7),
        enabled: _allEnabled,
        nudgeState: {
          RitualId.weeklyReview: NudgeState(dismissedAt: _at(0, 6)),
        },
      ));

      expect(
        _of(plan, RitualId.weeklyReview)
            .map((p) => p.fireAt),
        [for (var day = 1; day <= 6; day++) _at(day, 9)],
        reason: 'hidden for the rest of today, back with tomorrow\'s firing',
      );
    });

    test('a snooze adds an alarm at its expiry', () {
      final plan = planNudgeNotifications(_facts(
        now: _at(0, 8, 10),
        nudgeState: {
          RitualId.dailyPlanning: NudgeState(snoozedUntil: _at(0, 8, 40)),
        },
      ));

      final snooze = _of(plan, RitualId.dailyPlanning)
          .firstWhere((p) => p.fireAt == _at(0, 8, 40));
      expect(snooze.id, ritualSnoozeNotificationId(RitualId.dailyPlanning));
      expect(
          parseRitualNotificationPayload(snooze.payload)!
              .edge!
              .isAtSameMomentAs(_at(0, 8)),
          isTrue);
    });

    test('a snooze that is over adds nothing', () {
      final plan = planNudgeNotifications(_facts(
        now: _at(0, 9),
        nudgeState: {
          RitualId.dailyPlanning: NudgeState(snoozedUntil: _at(0, 8, 40)),
        },
      ));

      expect(_of(plan, RitualId.dailyPlanning).map((p) => p.fireAt),
          isNot(contains(_at(0, 8, 40))));
    });

    test('a Ceremony in progress hides the current firing but not the next',
        () {
      final plan = planNudgeNotifications(_facts(
        now: _at(0, 8, 10),
        inProgress: const {RitualId.dailyPlanning},
        nudgeState: {
          RitualId.dailyPlanning: NudgeState(snoozedUntil: _at(0, 8, 40)),
        },
      ));

      expect(_of(plan, RitualId.dailyPlanning).map((p) => p.fireAt),
          isNot(contains(_at(0, 8, 40))),
          reason: 'the 08:00 firing is the one being performed');
      expect(_of(plan, RitualId.dailyPlanning).map((p) => p.fireAt),
          contains(_at(1, 8)),
          reason: 'tomorrow is a new firing');
    });
  });
}
