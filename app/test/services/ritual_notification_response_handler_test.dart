import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:jeeves/services/ritual_notification_response_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RecordingNotificationService service;
  final tappedAt = DateTime(2026, 11, 11, 8, 5);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service = RecordingNotificationService();
  });

  Future<void> tap(String actionId, String payload) =>
      handleRitualNotificationResponse(
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          actionId: actionId,
          payload: payload,
        ),
        service: service,
        navigate: (_) {},
        now: () => tappedAt,
      );

  String payloadFor(RitualId ritual, DateTime edge, {int snooze = 60}) =>
      ritualNotificationPayload(ritual,
          edge: edge, snoozeMinutes: snooze, fireAt: edge);

  test('Snooze re-arms after the duration in the payload', () async {
    await tap(kNotificationActionSnooze,
        payloadFor(RitualId.dailyPlanning, DateTime(2026, 11, 11, 8), snooze: 15));

    final alarm =
        service.pending[ritualSnoozeNotificationId(RitualId.dailyPlanning)]!;
    expect(alarm.fireAt, tappedAt.add(const Duration(minutes: 15)));
    expect(parseRitualNotificationPayload(alarm.payload)!.snoozeMinutes, 15);
  });

  test('Snooze cancels the Ritual\'s alarms inside the window and keeps later ones',
      () async {
    Future<void> arm(int id, DateTime at) => service.scheduleRitualNotification(
          id: id,
          ritual: RitualId.weeklyReview,
          fireAt: at,
          payload: ritualNotificationPayload(RitualId.weeklyReview,
              edge: DateTime(2026, 11, 10, 7), snoozeMinutes: 60, fireAt: at),
        );
    await arm(300, DateTime(2026, 11, 11, 9)); // inside 08:05 + 60 min
    await arm(301, DateTime(2026, 11, 12, 9)); // tomorrow

    await tap(kPeriodicReviewActionSnooze,
        payloadFor(RitualId.weeklyReview, DateTime(2026, 11, 10, 7)));

    expect(service.pending.containsKey(300), isFalse);
    expect(service.pending.containsKey(301), isTrue);
    expect(
        service.pending
            .containsKey(ritualSnoozeNotificationId(RitualId.weeklyReview)),
        isTrue);
  });

  test('Snooze also cancels overdue alarms still pending at or before the tap',
      () async {
    Future<void> arm(int id, DateTime at) => service.scheduleRitualNotification(
          id: id,
          ritual: RitualId.weeklyReview,
          fireAt: at,
          payload: ritualNotificationPayload(RitualId.weeklyReview,
              edge: DateTime(2026, 11, 10, 7), snoozeMinutes: 60, fireAt: at),
        );
    await arm(300, DateTime(2026, 11, 11, 8, 4)); // due, not yet delivered
    await arm(301, tappedAt); // due exactly at the tap
    await arm(302, DateTime(2026, 11, 12, 9)); // tomorrow

    await tap(kPeriodicReviewActionSnooze,
        payloadFor(RitualId.weeklyReview, DateTime(2026, 11, 10, 7)));

    expect(service.pending.containsKey(300), isFalse);
    expect(service.pending.containsKey(301), isFalse);
    expect(service.pending.containsKey(302), isTrue);
  });

  String planningPayload({DateTime? outrankedFrom}) => ritualNotificationPayload(
        RitualId.dailyPlanning,
        edge: DateTime(2026, 11, 11, 8),
        snoozeMinutes: 60,
        fireAt: DateTime(2026, 11, 11, 8),
        outrankedFrom: outrankedFrom,
      );

  test('Snooze does not arm an expiry alarm once a higher-priority Ritual '
      'holds the head, even with nothing of it pending', () async {
    // Weekly Review became due at 08:30 (its notification is at 18:00, or was
    // already delivered); Daily Planning snoozed at 08:05 expires at 09:05.
    await tap(kNotificationActionSnooze,
        planningPayload(outrankedFrom: DateTime(2026, 11, 11, 8, 30)));

    expect(
        service.pending
            .containsKey(ritualSnoozeNotificationId(RitualId.dailyPlanning)),
        isFalse);
  });

  test('Snooze still arms when the higher-priority Ritual takes the head only '
      'after the expiry', () async {
    await tap(kNotificationActionSnooze,
        planningPayload(outrankedFrom: DateTime(2026, 11, 11, 9, 30)));

    final alarm =
        service.pending[ritualSnoozeNotificationId(RitualId.dailyPlanning)]!;
    expect(
        parseRitualNotificationPayload(alarm.payload)!.outrankedFrom,
        DateTime(2026, 11, 11, 9, 30));
  });

  test('Snooze on a notification from an older build falls back to an hour',
      () async {
    await tap(kNotificationActionSnooze, 'nudge:planning');

    expect(
        service.pending[ritualSnoozeNotificationId(RitualId.dailyPlanning)]!
            .fireAt,
        tappedAt.add(const Duration(hours: 1)));
  });

  test('Skip cancels the Ritual\'s alarms of the skipped firing only',
      () async {
    final thisPeriod = DateTime(2026, 11, 10, 7);
    final nextPeriod = DateTime(2026, 11, 17, 7);
    Future<void> arm(int id, DateTime edge) => service.scheduleRitualNotification(
          id: id,
          ritual: RitualId.weeklyReview,
          fireAt: DateTime(2026, 11, 12 + id % 100, 9),
          payload: payloadFor(RitualId.weeklyReview, edge),
        );
    await arm(300, thisPeriod);
    await arm(301, thisPeriod);
    await arm(302, nextPeriod);
    await service.scheduleRitualNotification(
      id: 201,
      ritual: RitualId.dailyPlanning,
      fireAt: DateTime(2026, 11, 12, 8),
      payload: payloadFor(RitualId.dailyPlanning, thisPeriod),
    );

    await tap(kPeriodicReviewActionSkip,
        payloadFor(RitualId.weeklyReview, thisPeriod));

    expect(service.pending.keys, containsAll([302, 201]));
    expect(service.pending.containsKey(300), isFalse);
    expect(service.pending.containsKey(301), isFalse);
  });

  test('the Weekly Review skip action reads "Skip this week"', () {
    expect(ritualSkipActionLabel(RitualId.weeklyReview), 'Skip this week');
    expect(ritualSkipActionLabel(RitualId.dailyPlanning), 'Skip today');
    expect(ritualSkipActionLabel(RitualId.eveningShutdown), 'Skip today');
  });
}
