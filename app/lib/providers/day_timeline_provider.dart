/// Providers behind the day timeline: the in-memory last layout and the three
/// reads the Now screen's timeline needs beyond the Plan's Outcomes.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/day_timeline.dart';
import '../models/time_context.dart';
import 'database_provider.dart';
import 'focus_session_planning_provider.dart'
    show kFallbackAvailableMinutes, kLastSessionAvailableMinutesKey;
import 'focus_session_planning_settings_provider.dart';
import 'focus_settings_provider.dart';
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

/// The context tags of the open session's Plan Outcomes (issue #407).
final activeSessionContextTagsProvider =
    StreamProvider<Map<String, List<({String id, String name})>>>((ref) {
  return ref
      .watch(databaseProvider)
      .tagDao
      .watchContextTagsForActiveSessionPlan();
});

/// The accepted batch and declined suggestion of each Plan entry of the open
/// session (issue #407).
final activeSessionBatchStateProvider =
    StreamProvider<Map<String, ({String? batchId, bool declined})>>((ref) {
  return ref
      .watch(databaseProvider)
      .focusSessionDao
      .watchActiveSessionBatchState();
});

/// The current Action's Time context for every Outcome that has one, live.
final currentTimeContextsProvider =
    StreamProvider<Map<String, TimeContext>>((ref) {
  return ref.watch(databaseProvider).actionDao.watchCurrentTimeContexts();
});

/// The recorded Sprints, live, with the Outcome each ran on.
///
/// The Sprint record is the only source of truth for what was done (issue
/// #910), so a Sprint that arrives by sync — projected into the domain store by
/// the sync host — reaches the tile without a restart.
final dayTimelineSprintsProvider =
    StreamProvider<List<TileSprintMark>>((ref) {
  return ref
      .watch(databaseProvider)
      .sprintDao
      .watchRecordsByOutcome()
      .map(tileSprintMarks);
});

/// The same, read once when the planning completion screen opens: a screen
/// that is left within a minute needs no live query.
final planningTimeContextsProvider =
    FutureProvider.autoDispose<Map<String, TimeContext>>((ref) {
  return ref.watch(databaseProvider).actionDao.getCurrentTimeContexts();
});

/// The recorded Sprints, read once when the planning completion screen opens,
/// for the same reason as [planningTimeContextsProvider].
final planningSprintMarksProvider =
    FutureProvider.autoDispose<List<TileSprintMark>>((ref) {
  return ref
      .watch(databaseProvider)
      .sprintDao
      .getRecordsByOutcome()
      .then(tileSprintMarks);
});

/// The two settings the timeline reads: what an Outcome with no estimate counts
/// as, and the chunking unit (sprint plus short break).
class DayTimelineSettings {
  const DayTimelineSettings({
    this.defaultEstimateMinutes = 10,
    this.chunkUnitMinutes = 23,
  });

  final int defaultEstimateMinutes;
  final int chunkUnitMinutes;
}

final dayTimelineSettingsProvider = Provider<DayTimelineSettings>((ref) {
  final focus = ref.watch(focusSettingsProvider);
  return DayTimelineSettings(
    defaultEstimateMinutes: ref.watch(
        focusSessionPlanningSettingsProvider.select((s) => s.defaultTimeEstimate)),
    chunkUnitMinutes:
        focus.sprintDurationMinutes + focus.shortBreakDurationMinutes,
  );
});

/// Everything the Now screen's timeline reads beyond the Plan's Outcomes,
/// gathered behind one provider so a screen test overrides one thing.
class NowTimelineExtras {
  const NowTimelineExtras({
    this.pinnedStarts = const {},
    this.engagedTaskIds = const {},
    this.timeContexts = const {},
    this.contextTags = const {},
    this.batchState = const {},
    this.sprintMarks = const [],
    this.availableMinutes = kFallbackAvailableMinutes,
    this.settings = const DayTimelineSettings(),
  });

  final Map<String, DateTime> pinnedStarts;
  final Set<String> engagedTaskIds;
  final Map<String, TimeContext> timeContexts;

  /// Each Plan Outcome's context tags, for the small-task suggestion.
  final Map<String, List<({String id, String name})>> contextTags;

  /// Each Plan entry's accepted batch and declined suggestion.
  final Map<String, ({String? batchId, bool declined})> batchState;

  /// The Sprints done, as the timeline draws them: a bar in the lane at the
  /// time it ran, and a count on the tile it ran on.
  final List<TileSprintMark> sprintMarks;

  /// The available time the open session was planned with; the preference that
  /// remembers it, or the fallback when none was recorded.
  final int availableMinutes;
  final DayTimelineSettings settings;
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
    contextTags:
        ref.watch(activeSessionContextTagsProvider).asData?.value ?? const {},
    batchState:
        ref.watch(activeSessionBatchStateProvider).asData?.value ?? const {},
    sprintMarks:
        ref.watch(dayTimelineSprintsProvider).asData?.value ?? const [],
    availableMinutes: remembered != null && remembered > 0
        ? remembered
        : kFallbackAvailableMinutes,
    settings: ref.watch(dayTimelineSettingsProvider),
  );
});
