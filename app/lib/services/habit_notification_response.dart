/// Handles a tap on a Habit's notification or on its "Check in" button.
///
/// The button can run in a background isolate, which has no Riverpod
/// container and no database — only [SharedPreferences]. So a Check-in is
/// written to the outbox ([appendHabitCheckIn]) and the main isolate applies
/// it when it next runs. A body tap opens the Habit's detail, which needs the
/// router and so only ever happens in the foreground.
///
/// [service] and [navigate] are the OS-plugin and router boundaries; tests
/// substitute them, production passes the real ones.
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/habit_commitment.dart' show habitDayKey;
import '../providers/habit_check_in_outbox.dart';
import '../utils/uuid.dart';
import 'habit_notifications.dart';
import 'notification_service.dart'
    show NotificationService, kNotificationActionHabitCheckIn;
import 'ritual_notification_response_handler.dart';

/// Handles a response for a Habit's notification.
///
/// A "Check in" tap records the Check-in in the outbox and nothing else: the
/// notification goes, and the Check-in appears in the database the next time
/// the app runs. A body tap opens the detail of the first Habit the
/// notification names.
Future<void> handleHabitNotificationResponse(
  NotificationResponse response, {
  required NotificationService service,
  required void Function(String route) navigate,
  DateTime Function() now = DateTime.now,
}) async {
  final payload = parseHabitNotificationPayload(response.payload);
  if (payload == null) return;

  if (response.actionId == kNotificationActionHabitCheckIn) {
    final tappedAt = now();
    await appendHabitCheckIn(PendingHabitCheckIn(
      checkInId: uuid.v4(),
      habitId: payload.habitId,
      // The Check-in counts for the calendar day of the tap.
      countsForDay: habitDayKey(tappedAt),
      at: tappedAt,
    ));
    return;
  }

  // A body tap opens the Habit itself.
  navigate('/habits/${payload.habitId}');
}

/// Routes a notification response to the handler that owns its payload.
///
/// A Habit's notification is handled before the Ritual one, so a body tap on
/// it never falls through to the inbox.
Future<void> handleNotificationResponse(
  NotificationResponse response, {
  required NotificationService service,
  required void Function(String route) navigate,
  DateTime Function() now = DateTime.now,
}) async {
  if (parseHabitNotificationPayload(response.payload) != null) {
    await handleHabitNotificationResponse(
      response,
      service: service,
      navigate: navigate,
      now: now,
    );
    return;
  }
  await handleRitualNotificationResponse(
    response,
    service: service,
    navigate: navigate,
    now: now,
  );
}
