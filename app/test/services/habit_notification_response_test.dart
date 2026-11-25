/// A tap on a Habit's notification: the "Check in" button records the
/// Check-in in the outbox, the "Start Focus" button opens Focus Mode on the
/// Habit, and a body tap opens the Habit's detail.
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/providers/habit_check_in_outbox.dart';
import 'package:jeeves/screens/habits/habit_routes.dart';
import 'package:jeeves/services/habit_notifications.dart';
import 'package:jeeves/services/habit_notification_response.dart';
import 'package:jeeves/services/notification_service.dart';

import '../test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RecordingNotificationService service;
  final routes = <String>[];
  final tappedAt = DateTime(2026, 11, 20, 6, 30);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service = RecordingNotificationService();
    routes.clear();
  });

  String payloadFor(
    String habitId, {
    HabitNotificationAction action = HabitNotificationAction.checkIn,
  }) =>
      habitNotificationPayload(
        firstHabitId: habitId,
        clockTimeHabitId: habitId,
        day: '2026-11-20',
        fireAt: tappedAt,
        action: action,
        signature: 'abcdef',
      );

  NotificationResponse checkInTap(String payload) => NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: kNotificationActionHabitCheckIn,
        payload: payload,
      );

  NotificationResponse startFocusTap(String payload) => NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: kNotificationActionHabitStartFocus,
        payload: payload,
      );

  NotificationResponse bodyTap(String payload) => NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotification,
        payload: payload,
      );

  Future<void> handle(NotificationResponse response) =>
      handleHabitNotificationResponse(
        response,
        service: service,
        navigate: routes.add,
        now: () => tappedAt,
      );

  Future<List<String>> outboxKeys() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs
        .getKeys()
        .where((k) => k.startsWith(kHabitCheckInOutboxKeyPrefix))
        .toList();
  }

  test('a Check in tap writes one outbox entry and navigates nowhere',
      () async {
    await handle(checkInTap(payloadFor('h1')));

    final keys = await outboxKeys();
    expect(keys, hasLength(1));
    expect(routes, isEmpty);

    final prefs = await SharedPreferences.getInstance();
    final entry =
        PendingHabitCheckIn.tryParse(prefs.getString(keys.first)!);
    expect(entry, isNotNull);
    expect(entry!.habitId, 'h1');
    // The Check-in counts for the calendar day of the tap.
    expect(entry.countsForDay, '2026-11-20');
    // The outbox keeps the instant, not the zone it was written in.
    expect(entry.at.isAtSameMomentAs(tappedAt), isTrue);
    expect(entry.checkInId, isNotEmpty);
  });

  test('a body tap opens the Habit the notification names', () async {
    await handle(bodyTap(payloadFor('h1')));

    expect(routes, ['/habits/h1']);
    expect(await outboxKeys(), isEmpty);
  });

  test('a Start Focus tap opens Focus Mode on the Habit', () async {
    await handle(startFocusTap(payloadFor(
      'h1',
      action: HabitNotificationAction.startFocus,
    )));

    expect(routes, ['/habits/h1/focus']);
  });

  test('a Start Focus tap records no Check-in', () async {
    await handle(startFocusTap(payloadFor(
      'h1',
      action: HabitNotificationAction.startFocus,
    )));

    expect(await outboxKeys(), isEmpty);
  });

  test('the routes the handler opens are the Habit screens’ own', () {
    // The service may not import a screen, so it writes the paths itself.
    // The tests above hold the handler to these two.
    expect(habitDetailPath('h1'), '/habits/h1');
    expect(habitFocusPath('h1'), '/habits/h1/focus');
  });

  test("a Habit's body tap never reaches the inbox", () async {
    await handleNotificationResponse(
      bodyTap(payloadFor('h1')),
      service: service,
      navigate: routes.add,
      now: () => tappedAt,
    );

    expect(routes, ['/habits/h1']);
    expect(routes, isNot(contains('/inbox')));
  });

  test("another kind of notification still reaches the inbox", () async {
    await handleNotificationResponse(
      bodyTap('outcome:abc'),
      service: service,
      navigate: routes.add,
      now: () => tappedAt,
    );

    expect(routes, ['/task/abc']);
  });
}
