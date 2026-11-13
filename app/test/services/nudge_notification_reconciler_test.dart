import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/nudge_predicates.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:jeeves/services/nudge_notification_scheduler.dart';

import '../test_helpers.dart';

DateTime _at(int dayOffset, int hour, [int minute = 0]) =>
    DateTime(2026, 11, 11 + dayOffset, hour, minute);

NudgeNotificationFacts _facts({
  DateTime? now,
}) {
  final instant = now ?? _at(0, 7);
  return NudgeNotificationFacts(
    now: instant,
    // Weekly Review is off: with it on, it falls due inside the horizon and
    // outranks Daily Planning from then on.
    notificationEnabled: const {
      RitualId.dailyPlanning: true,
      RitualId.eveningShutdown: true,
      RitualId.weeklyReview: false,
    },
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
    es: const EsFacts(shutdownHour: 18, shutdownMinute: 0, sessionIsOpen: false),
    wr: WrFacts(
      hasAnyItem: true,
      lastCompleted: instant.subtract(const Duration(days: 2)),
    ),
    weeklyReviewHour: 9,
    weeklyReviewMinute: 0,
    snoozeMinutes: const {},
  );
}

Future<void> _seed(
  RecordingNotificationService service,
  int id,
  RitualId ritual,
  String payload,
) =>
    service.scheduleRitualNotification(
        id: id, ritual: ritual, fireAt: _at(3, 8), payload: payload);

void main() {
  late RecordingNotificationService service;
  late NudgeNotificationScheduler scheduler;

  setUp(() {
    service = RecordingNotificationService();
    scheduler = NudgeNotificationScheduler(service);
  });

  test('schedules the plan, and an unchanged second pass schedules nothing',
      () async {
    await scheduler.reconcile(_facts());
    final firstPass = service.scheduleCalls.length;
    expect(firstPass, 8, reason: 'seven daily alarms and a keep-alive');
    expect(service.pending.values.where((a) => a.isKeepAlive), hasLength(1));

    await scheduler.reconcile(_facts());

    expect(service.scheduleCalls.length, firstPass,
        reason: 'ids are per (Ritual, date): a restart must not churn');
  });

  test('re-schedules an alarm whose fire instant changed under the same id',
      () async {
    await scheduler.reconcile(_facts());
    final before = service.scheduleCalls.length;
    final changed = NudgeNotificationFacts(
      now: _at(0, 7),
      notificationEnabled: _facts().notificationEnabled,
      nudgeState: const {},
      inProgress: const {},
      dpr: const DprFacts(
        planningHour: 8,
        planningMinute: 30,
        shutdownHour: 18,
        shutdownMinute: 0,
        hasAnyItem: true,
        hasInboxOrNext: true,
      ),
      es: _facts().es,
      wr: _facts().wr,
      weeklyReviewHour: 9,
      weeklyReviewMinute: 0,
      snoozeMinutes: const {},
    );

    await scheduler.reconcile(changed);

    expect(service.scheduleCalls.length, before + 8);
    expect(service.alarmsOf(RitualId.dailyPlanning).first.fireAt, _at(0, 8, 30));
  });

  test('cancels the fixed ids earlier builds armed and alarms it did not plan',
      () async {
    await _seed(service, 0, RitualId.dailyPlanning, 'nudge:planning');
    await _seed(service, 4, RitualId.eveningShutdown, 'nudge:shutdown');
    await _seed(service, 6, RitualId.weeklyReview, 'nudge:periodic_review');
    await _seed(service, 450, RitualId.dailyPlanning,
        ritualNotificationPayload(RitualId.dailyPlanning,
            edge: _at(5, 8), snoozeMinutes: 60, fireAt: _at(5, 8)));

    await scheduler.reconcile(_facts());

    expect(service.pending.containsKey(0), isFalse);
    expect(service.pending.containsKey(4), isFalse);
    expect(service.pending.containsKey(6), isFalse);
    expect(service.pending.containsKey(450), isFalse);
  });

  test('withdraws a delivered notification once its Ritual no longer holds '
      'the surface, and keeps the one that does', () async {
    service.delivered
      ..add((id: 7, ritual: RitualId.weeklyReview))
      ..add((id: 130, ritual: RitualId.dailyPlanning));

    // 08:30: Planning is firing; Weekly Review's notifications are off.
    await scheduler.reconcile(_facts(now: _at(0, 8, 30)));

    expect(service.delivered.map((d) => d.ritual), [RitualId.dailyPlanning]);
  });

  test('cancels an alarm of a Ritual that no longer notifies', () async {
    await scheduler.reconcile(_facts());
    await _seed(service, 450, RitualId.weeklyReview,
        ritualNotificationPayload(RitualId.weeklyReview,
            edge: _at(-1, 7), snoozeMinutes: 60, fireAt: _at(1, 9)));

    await scheduler.reconcile(_facts());

    expect(service.alarmsOf(RitualId.weeklyReview), isEmpty,
        reason: 'Weekly Review notifications are off, so its stale alarm is cancelled');
  });

  test('enqueue reconciles in the background and settled() waits for it',
      () async {
    await scheduler.enqueue(_facts());
    await scheduler.settled();

    expect(service.pending, isNotEmpty);
  });
}
