import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/services/notification_service.dart';

// Deliberately no initializeTimeZones / setLocalLocation / initialize: a test
// file is a fresh isolate, which is the condition of the background isolate
// the notification plugin starts for Snooze and Skip taps. `tz.local` is
// unset there, so building the alarm time must not touch it.
void main() {
  test('ritualAlarmScheduledDate works without any timezone setup', () {
    final fireAt = DateTime.utc(2026, 11, 14, 9, 30);

    final scheduled = ritualAlarmScheduledDate(fireAt);

    expect(scheduled.isAtSameMomentAs(fireAt), isTrue);
  });
}
