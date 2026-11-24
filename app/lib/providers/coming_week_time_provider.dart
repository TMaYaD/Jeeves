import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/coming_week_time.dart';
import 'clock_provider.dart';
import 'time_context_provider.dart';
import 'time_window_provider.dart';

/// The line that says when each Outcome's time opens in the coming week,
/// keyed by Outcome id (GitHub #1073).
///
/// An Outcome whose time does not open in the seven days starting today is
/// absent: the review shows it as it does today, with no line.
///
/// Read-time only. Nothing is stored and nothing syncs — the line is derived
/// from the windows and Time contexts the current Actions carry.
final comingWeekTimeLinesProvider = Provider<Map<String, String>>((ref) {
  final now = ref.watch(clockProvider)();
  final windows = ref.watch(currentTimeWindowsProvider).value ?? const {};
  final contexts = ref.watch(currentTimeContextsProvider).value ?? const {};
  final lines = <String, String>{};
  for (final entry in windows.entries) {
    final line = comingWeekTimeLine(window: entry.value, now: now);
    if (line != null) lines[entry.key] = line;
  }
  for (final entry in contexts.entries) {
    // A named window wins over a Time context: an Action carries one time,
    // and the two are exclusive.
    if (lines.containsKey(entry.key)) continue;
    final line = comingWeekTimeLine(timeContext: entry.value, now: now);
    if (line != null) lines[entry.key] = line;
  }
  return lines;
});
