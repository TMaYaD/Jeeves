/// Providers behind the day timeline: the in-memory last layout and the three
/// reads the Now screen's timeline needs beyond the Plan's Outcomes.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/day_timeline.dart';
import '../models/time_context.dart';
import 'database_provider.dart';
import 'focus_session_planning_provider.dart'
    show kFallbackAvailableMinutes, kLastSessionAvailableMinutesKey;
import 'synced_preferences_provider.dart' show syncedPreferencesProvider;

/// The last layout worked out. Memory only: it is never stored, synced or
/// cached on the device, so it is gone when the app is (the layout is then
/// rebuilt from the flow origin). One instance, shared by both screens that
/// draw the timeline.
final dayTimelineLastLayoutProvider =
    Provider<LastDayLayout>((ref) => LastDayLayout());

/// Start times the user set on the open session's Plan entries.
final activeSessionPinnedStartsProvider =
    StreamProvider<Map<String, DateTime>>((ref) {
  return ref
      .watch(databaseProvider)
      .focusSessionDao
      .watchActiveSessionPinnedStarts();
});

/// Outcomes engaged in the open session (a TimeLog is attributed to it).
final activeSessionEngagedTaskIdsProvider = StreamProvider<Set<String>>((ref) {
  return ref
      .watch(databaseProvider)
      .focusSessionDao
      .watchActiveSessionEngagedTaskIds();
});

/// The current Action's Time context for every Outcome that has one.
final currentTimeContextsProvider =
    StreamProvider<Map<String, TimeContext>>((ref) {
  return ref.watch(databaseProvider).actionDao.watchCurrentTimeContexts();
});

/// Everything the Now screen's timeline reads beyond the Plan's Outcomes,
/// gathered behind one provider so a screen test overrides one thing.
class NowTimelineExtras {
  const NowTimelineExtras({
    this.pinnedStarts = const {},
    this.engagedTaskIds = const {},
    this.timeContexts = const {},
    this.availableMinutes = kFallbackAvailableMinutes,
  });

  final Map<String, DateTime> pinnedStarts;
  final Set<String> engagedTaskIds;
  final Map<String, TimeContext> timeContexts;

  /// The available time the open session was planned with; the preference that
  /// remembers it, or the fallback when none was recorded.
  final int availableMinutes;
}

final nowTimelineExtrasProvider = Provider<NowTimelineExtras>((ref) {
  final remembered = ref
      .watch(syncedPreferencesProvider)
      .asData
      ?.value
      .get<int>(kLastSessionAvailableMinutesKey);
  return NowTimelineExtras(
    pinnedStarts:
        ref.watch(activeSessionPinnedStartsProvider).asData?.value ?? const {},
    engagedTaskIds:
        ref.watch(activeSessionEngagedTaskIdsProvider).asData?.value ??
            const {},
    timeContexts:
        ref.watch(currentTimeContextsProvider).asData?.value ?? const {},
    availableMinutes: remembered != null && remembered > 0
        ? remembered
        : kFallbackAvailableMinutes,
  );
});
