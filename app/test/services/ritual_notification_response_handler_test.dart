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

  test('Skip leaves the repeating keep-alive armed', () async {
    final edge = DateTime(2026, 11, 10, 7);
    final keepAliveId = kRitualKeepAliveIdBase +
        RitualId.values.indexOf(RitualId.weeklyReview);
    await service.scheduleRitualKeepAlive(
      id: keepAliveId,
      ritual: RitualId.weeklyReview,
      firstFireAt: DateTime(2026, 11, 18, 9),
      payload: payloadFor(RitualId.weeklyReview, edge),
    );

    await tap(kPeriodicReviewActionSkip, payloadFor(RitualId.weeklyReview, edge));

    expect(service.pending.containsKey(keepAliveId), isTrue);
  });

  test('the Weekly Review skip action reads "Skip this week"', () {
    expect(ritualSkipActionLabel(RitualId.weeklyReview), 'Skip this week');
    expect(ritualSkipActionLabel(RitualId.dailyPlanning), 'Skip today');
    expect(ritualSkipActionLabel(RitualId.eveningShutdown), 'Skip today');
  });
}
