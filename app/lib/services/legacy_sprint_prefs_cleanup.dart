/// One-time, remove-only cleanup of the device-only Sprint timer keys.
///
/// Before Sprints were recorded (issue #910) the timer kept its state in these
/// SharedPreferences keys. Nothing reads them any more; this deletes them so the
/// task title they held does not linger on the device. It writes nothing.
library;

import 'package:shared_preferences/shared_preferences.dart';

const List<String> legacySprintPrefKeys = [
  'sprint_active_task_id',
  'sprint_active_task_title',
  'sprint_end_time',
  'sprint_phase',
  'sprint_sprint_number',
  'sprint_total_sprints',
  'sprint_is_paused',
  'sprint_remaining_seconds',
  'sprint_sprint_duration_minutes',
  'sprint_break_duration_minutes',
  'sprint_last_break_ended_at',
  'sprint_overtime_start_ms',
];

Future<void> removeLegacySprintPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  for (final key in legacySprintPrefKeys) {
    if (prefs.containsKey(key)) await prefs.remove(key);
  }
}
