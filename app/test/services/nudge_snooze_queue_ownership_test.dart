import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/nudge_predicates.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:jeeves/services/nudge_notification_scheduler.dart';
import 'package:jeeves/services/ritual_notification_response_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

/// A background Snooze has no database, so whether its expiry is outranked must
/// be decidable from the payload the planner wrote. These tests run
/// planner-generated payloads through the real handler.
DateTime _at(int dayOffset, int hour, [int minute = 0]) =>
    DateTime(2026, 11, 11 + dayOffset, hour, minute);

NudgeNotificationFacts _facts({
  required Map<RitualId, bool> enabled,
  DateTime? weeklyReviewLastCompleted,
  bool sessionIsOpen = false,
}) {
  final now = _at(0, 7);
  return NudgeNotificationFacts(
    now: now,
    notificationEnabled: enabled,
    nudgeState: const {},
    inProgress: const {},
    dpr: const DprFacts(
      planningHour: 8,
      planningMinute: 0,
      shutdownHour: 18,
      shutdownMinute: 0,
      hasAnyItem: true,
      hasInboxOrNext: true,
    ),
    es: EsFacts(
      shutdownHour: 18,
      shutdownMinute: 0,
      sessionIsOpen: sessionIsOpen,
    ),
    wr: WrFacts(
      dueAt: (weeklyReviewLastCompleted ?? now.subtract(const Duration(days: 2)))
          .add(const Duration(days: 7)),
    ),
    weeklyReviewHour: 18,
    weeklyReviewMinute: 0,
    snoozeMinutes: const {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RecordingNotificationService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service = RecordingNotificationService();
  });

  Future<void> snoozePlanningAlarm(
    NudgeNotificationFacts facts, {
    required DateTime alarmAt,
    required DateTime tappedAt,
  }) {
    final alarm = planNudgeNotifications(facts).firstWhere(
        (p) => p.ritual == RitualId.dailyPlanning && p.fireAt == alarmAt);
    return handleRitualNotificationResponse(
      NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: kNotificationActionSnooze,
        payload: alarm.payload,
      ),
      service: service,
      navigate: (_) {},
      now: () => tappedAt,
    );
  }

  bool snoozeArmed() => service.pending
      .containsKey(ritualSnoozeNotificationId(RitualId.dailyPlanning));

  const allEnabled = {
    RitualId.dailyPlanning: true,
    RitualId.eveningShutdown: true,
    RitualId.weeklyReview: true,
  };

  test('a higher-priority Nudge appearing between scan samples outranks the '
      'expiry', () async {
    // Weekly Review falls due at 09:01; the expiry is 09:02.
    await snoozePlanningAlarm(
      _facts(enabled: allEnabled, weeklyReviewLastCompleted: _at(-7, 9, 1)),
      alarmAt: _at(0, 8),
      tappedAt: _at(0, 8, 2),
    );
    expect(snoozeArmed(), isFalse,
        reason: '08:02 + 60 minutes = 09:02, after Weekly Review is due');
  });

  test('an expiry before the higher-priority Nudge appears still arms',
      () async {
    await snoozePlanningAlarm(
      _facts(enabled: allEnabled, weeklyReviewLastCompleted: _at(-7, 9, 1)),
      alarmAt: _at(0, 8),
      tappedAt: _at(0, 8),
    );
    expect(snoozeArmed(), isTrue, reason: '09:00 is before 09:01');
  });

  test('a higher-priority Nudge that later disappears does not block a later '
      'expiry', () async {
    // Weekly Review is off; a stale open session keeps Evening Shutdown
    // visible from 18:00 until the next morning.
    await snoozePlanningAlarm(
      _facts(
        enabled: const {
          RitualId.dailyPlanning: true,
          RitualId.eveningShutdown: true,
          RitualId.weeklyReview: false,
        },
        sessionIsOpen: true,
      ),
      alarmAt: _at(0, 8),
      tappedAt: _at(1, 7, 5),
    );
    expect(snoozeArmed(), isTrue,
        reason: 'Evening Shutdown is not visible at 08:05 the next morning');
  });

  test('a delayed tap after a higher-priority Nudge appeared is outranked, '
      'though the payload recorded nothing for the first day', () async {
    // Wednesday's 08:00 alarm; Weekly Review falls due Thursday 08:30.
    await snoozePlanningAlarm(
      _facts(enabled: allEnabled, weeklyReviewLastCompleted: _at(-6, 8, 30)),
      alarmAt: _at(0, 8),
      tappedAt: _at(1, 8, 35),
    );
    expect(snoozeArmed(), isFalse, reason: 'Thursday 09:35, Weekly Review holds the head');
  });

  test('a tap beyond what the payload covers arms nothing', () async {
    await snoozePlanningAlarm(
      _facts(
        enabled: allEnabled,
        weeklyReviewLastCompleted: _at(-1, 8),
      ),
      alarmAt: _at(0, 8),
      tappedAt: _at(12, 8, 5),
    );
    expect(snoozeArmed(), isFalse);
  });

  test('a repeated Snooze keeps the same facts', () async {
    await snoozePlanningAlarm(
      _facts(enabled: allEnabled, weeklyReviewLastCompleted: _at(-6, 8, 30)),
      alarmAt: _at(0, 8),
      tappedAt: _at(0, 8, 5),
    );
    final alarm = service
        .pending[ritualSnoozeNotificationId(RitualId.dailyPlanning)]!;
    final again = parseRitualNotificationPayload(alarm.payload)!;
    // Snoozed again from the 09:05 alarm at 09:06 -> 10:06, then 23:00 Thursday.
    expect(again.mayNotifyAt(_at(1, 8, 45)), isFalse);
    expect(again.mayNotifyAt(_at(0, 10, 6)), isTrue);
  });

  group('exact ownership boundaries', () {
    NudgeNotificationFacts custom({
      required DateTime now,
      required Map<RitualId, bool> enabled,
      int planningMinute = 0,
      int shutdownHour = 18,
      int shutdownMinute = 0,
      int planningSnoozeMinutes = 60,
      Map<RitualId, NudgeState> nudgeState = const {},
      bool sessionIsOpen = false,
      DateTime? weeklyReviewDueAt,
    }) =>
        NudgeNotificationFacts(
          now: now,
          notificationEnabled: enabled,
          nudgeState: nudgeState,
          inProgress: const {},
          dpr: DprFacts(
            planningHour: planningMinute == 1 ? 23 : 8,
            planningMinute: planningMinute,
            shutdownHour: shutdownHour,
            shutdownMinute: shutdownMinute,
            hasAnyItem: true,
            hasInboxOrNext: true,
          ),
          es: EsFacts(
            shutdownHour: shutdownHour,
            shutdownMinute: shutdownMinute,
            sessionIsOpen: sessionIsOpen,
          ),
          wr: WrFacts(dueAt: weeklyReviewDueAt),
          weeklyReviewHour: 9,
          weeklyReviewMinute: 0,
          snoozeMinutes: {RitualId.dailyPlanning: planningSnoozeMinutes},
        );

    test('an ownership interval shorter than the scan step is not lost',
        () async {
      // Evening Shutdown, snoozed to 23:59:30 from a retained notification,
      // holds the surface for [23:59:30, midnight): no minute sample lands in
      // it. Daily Planning's 23:44:40 Snooze expires at 23:59:40, inside it.
      final facts = custom(
        now: DateTime(2026, 11, 11, 23, 0, 10),
        enabled: const {
          RitualId.dailyPlanning: true,
          RitualId.eveningShutdown: true,
          RitualId.weeklyReview: false,
        },
        planningMinute: 1,
        shutdownHour: 23,
        shutdownMinute: 59,
        planningSnoozeMinutes: 15,
        sessionIsOpen: true,
        nudgeState: {
          RitualId.eveningShutdown:
              NudgeState(snoozedUntil: DateTime(2026, 11, 11, 23, 59, 30)),
        },
      );
      final alarmAt = DateTime(2026, 11, 11, 23, 1);
      await snoozePlanningAlarm(
        facts,
        alarmAt: alarmAt,
        tappedAt: DateTime(2026, 11, 11, 23, 44, 40),
      );
      expect(snoozeArmed(), isFalse,
          reason: '23:59:40 is inside Evening Shutdown\'s visibility');
    });

    test('a boundary is recorded to the instant, not a later sample', () {
      final facts = custom(
        now: DateTime(2026, 11, 11, 7),
        enabled: allEnabled,
        weeklyReviewDueAt: DateTime(2026, 11, 11, 9, 1),
      );
      final intervals =
          outrankedIntervals(RitualId.dailyPlanning, facts.now.add(const Duration(days: 1)), facts);
      expect(intervals.first.start, DateTime(2026, 11, 11, 9, 1));
    });

    test('coverage ends exclusively: an expiry exactly at the end arms nothing',
        () async {
      // Weekly Review falls due 08:30 on the first day and stays due, so the
      // outranked stretch runs to the payload's coverage end.
      final now = DateTime(2026, 11, 11, 7);
      final facts = custom(
        now: now,
        enabled: allEnabled,
        weeklyReviewDueAt: DateTime(2026, 11, 11, 8, 30),
      );
      final alarm = planNudgeNotifications(facts).firstWhere(
          (p) => p.ritual == RitualId.dailyPlanning && p.fireAt == DateTime(2026, 11, 11, 8));
      final cover = parseRitualNotificationPayload(alarm.payload)!.coveredUntil!;
      await handleRitualNotificationResponse(
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          actionId: kNotificationActionSnooze,
          payload: alarm.payload,
        ),
        service: service,
        navigate: (_) {},
        now: () => cover.subtract(const Duration(minutes: 60)),
      );
      expect(snoozeArmed(), isFalse);
    });
  });
}
