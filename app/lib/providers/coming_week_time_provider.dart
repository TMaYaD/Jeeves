import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/coming_week_time.dart';
import 'clock_provider.dart';
import 'current_action_provider.dart';

/// The line that says when each Outcome's time opens in the coming week,
/// keyed by Outcome id (GitHub #1073).
///
/// An Outcome whose time does not open in the seven days starting today is
/// absent: the review shows it as it does today, with no line.
///
/// Read-time only. Nothing is stored and nothing syncs — the line is derived
/// from the time the current Action carries.
final comingWeekTimeLinesProvider = Provider<Map<String, String>>((ref) {
  final now = ref.watch(clockProvider)();
  // The current Actions, read once: the line describes the same Action the
  // card's text describes, so the two can never be a pair of different
  // Actions.
  final actions = ref.watch(currentActionsProvider).value ?? const {};
  final lines = <String, String>{};
  for (final entry in actions.entries) {
    // A named window wins over a Time context: an Action carries one time,
    // and the two are exclusive.
    final line = comingWeekTimeLine(
      window: entry.value.timeWindow,
      timeContext: entry.value.timeContext,
      now: now,
    );
    if (line != null) lines[entry.key] = line;
  }
  return lines;
});
