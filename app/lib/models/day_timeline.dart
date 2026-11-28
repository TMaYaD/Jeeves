/// The day timeline's inputs and its re-flow rule.
///
/// Plain data and one pure function over [autoflow]: no Flutter widgets, no
/// database, no clock read. The widget keeps a [LastDayLayout] in memory so that
/// a re-flow can leave started and engaged entries where they were; nothing
/// here is stored or synced (only a time the user sets is, as the Plan entry's
/// `pinned_start_at`).
library;

import '../database/daos/sprint_dao.dart' show SprintOutcomeRecord;
import '../database/gtd_database.dart' show Todo;
import 'autoflow.dart';
import 'time_context.dart';

/// One Plan entry as the timeline draws it.
class DayTimelineEntry {
  const DayTimelineEntry({
    required this.outcomeId,
    required this.title,
    required this.estimateMinutes,
    this.isDefaultEstimate = false,
    this.timeContext,
    this.pinnedStartAt,
    this.isDone = false,
    this.isRunning = false,
    this.isEngaged = false,
    this.isTimeboxed = false,
    this.contextTags = const [],
    this.batchId,
    this.isBatchSuggestionDeclined = false,
  });

  final String outcomeId;
  final String title;

  /// Minutes to place, with the default estimate already applied.
  final int estimateMinutes;
  final bool isDefaultEstimate;
  final TimeContext? timeContext;

  /// The time the user set ("Set by you"); null when Jeeves places it.
  final DateTime? pinnedStartAt;
  final bool isDone;

  /// The Outcome in Focus right now.
  final bool isRunning;

  /// A TimeLog is attributed to this session, or the entry is done or running:
  /// the entry is never re-flowed.
  final bool isEngaged;

  /// Heavier bottom edge on the tile: the Outcome's current Action is
  /// Timeboxed, so its estimate is a limit (issue #923).
  final bool isTimeboxed;

  /// The Outcome's context tags (for example "@phone"), in tag order. A small-task
  /// suggestion groups entries by these (issue #407).
  final List<({String id, String name})> contextTags;

  /// The accepted small-task suggestion this entry belongs to; null = none.
  final String? batchId;

  /// The user answered "Not today" to a suggestion that included this entry.
  final bool isBatchSuggestionDeclined;

  /// A comparable summary of everything the layout depends on, so the widget
  /// re-flows when an input changed and not when only time passed.
  String get layoutSignature => [
        outcomeId,
        estimateMinutes,
        timeContext?.encode() ?? '',
        pinnedStartAt?.toUtc().toIso8601String() ?? '',
        isEngaged || isDone || isRunning,
        contextTags.map((tag) => tag.id).join(','),
        batchId ?? '',
        isBatchSuggestionDeclined,
      ].join('|');
}

/// The Plan's Outcomes as timeline entries, in Plan order.
///
/// An Outcome with no estimate counts at [defaultEstimateMinutes]. A pin dated
/// before the day started is ignored: a time set on an earlier day means
/// nothing today.
///
/// [timeboxedTaskIds] names the Outcomes whose current Action is Timeboxed:
/// their tiles carry the heavier bottom edge (issue #923). An Outcome absent
/// from the set is not Timeboxed, so its tile keeps the ordinary edge.
///
/// [contextTags] and [batchState] feed the small-task suggestion (issue #407):
/// each Outcome's context tags, and the accepted batch / declined suggestion of
/// each Plan entry. An Outcome absent from either has none.
List<DayTimelineEntry> dayTimelineEntriesFor({
  required List<Todo> tasks,
  required int defaultEstimateMinutes,
  required DateTime now,
  Map<String, TimeContext> timeContexts = const {},
  Map<String, DateTime> pinnedStarts = const {},
  Set<String> engagedTaskIds = const {},
  String? runningTaskId,
  Set<String> timeboxedTaskIds = const {},
  Map<String, List<({String id, String name})>> contextTags = const {},
  Map<String, ({String? batchId, bool declined})> batchState = const {},
}) {
  final startOfToday = DateTime(now.year, now.month, now.day);
  return [
    for (final task in tasks)
      () {
        final estimate = task.timeEstimate;
        final pinned = pinnedStarts[task.id]?.toLocal();
        final isDone = task.doneAt != null;
        final isRunning = task.id == runningTaskId;
        return DayTimelineEntry(
          outcomeId: task.id,
          title: task.title,
          estimateMinutes:
              estimate != null && estimate > 0 ? estimate : defaultEstimateMinutes,
          isDefaultEstimate: estimate == null || estimate <= 0,
          timeContext: timeContexts[task.id],
          pinnedStartAt:
              pinned != null && !pinned.isBefore(startOfToday) ? pinned : null,
          isDone: isDone,
          isRunning: isRunning,
          isEngaged: isDone || isRunning || engagedTaskIds.contains(task.id),
          isTimeboxed: timeboxedTaskIds.contains(task.id),
          contextTags: contextTags[task.id] ?? const [],
          batchId: batchState[task.id]?.batchId,
          isBatchSuggestionDeclined: batchState[task.id]?.declined ?? false,
        );
      }(),
  ];
}

/// One recorded Sprint as the day timeline draws it.
///
/// The Sprint is a fact about the Outcome it ran on: when it ran and for how
/// long. The timeline draws it in the lane at the tile's right edge, at its
/// real time, and counts it in the tile.
class TileSprintMark {
  const TileSprintMark({
    required this.id,
    required this.outcomeId,
    required this.startedAt,
    required this.endedAt,
  });

  /// The Sprint's id, so one mark can be named.
  final String id;

  /// The Outcome the Sprint ran on.
  final String outcomeId;

  /// When the Sprint started, in local time.
  final DateTime startedAt;

  /// When it ended, in local time; null while it still runs.
  final DateTime? endedAt;

  /// The minutes the Sprint has taken: its end minus its start, or the time
  /// since it started while it runs.
  int durationMinutesAt(DateTime now) {
    final end = endedAt ?? now;
    final minutes = end.difference(startedAt).inMinutes;
    return minutes < 0 ? 0 : minutes;
  }
}

/// The recorded Sprints as the day timeline draws them: local instants, one
/// mark per Sprint, each naming the Outcome it ran on.
List<TileSprintMark> tileSprintMarks(List<SprintOutcomeRecord> records) => [
      for (final record in records)
        TileSprintMark(
          id: record.record.id,
          outcomeId: record.outcomeId,
          startedAt: record.record.startedAtUtc.toLocal(),
          endedAt: record.record.endedAtUtc?.toLocal(),
        ),
    ];

/// The Sprints of [marks] grouped by the Outcome they ran on, each group in
/// the order the Sprints ran.
Map<String, List<TileSprintMark>> tileSprintMarksByOutcome(
    List<TileSprintMark> marks) {
  final byOutcome = <String, List<TileSprintMark>>{};
  for (final mark in marks) {
    (byOutcome[mark.outcomeId] ??= []).add(mark);
  }
  return byOutcome;
}

/// The Sprints of [marks] that ran on the day of [day], grouped by the Outcome
/// they ran on.
///
/// The day timeline is one day's record: a Sprint from another day is not part
/// of it, and a Sprint on an Outcome with no tile is not drawn either.
Map<String, List<TileSprintMark>> tileSprintMarksOfDay(
  List<TileSprintMark> marks,
  DateTime day,
) {
  final startOfDay = DateTime(day.year, day.month, day.day);
  final endOfDay = startOfDay.add(const Duration(days: 1));
  final ofDay = [
    for (final mark in marks)
      if (!mark.startedAt.isBefore(startOfDay) && mark.startedAt.isBefore(endOfDay))
        mark,
  ];
  return tileSprintMarksByOutcome(ofDay);
}

/// The next multiple of five minutes at or after [instant], seconds dropped.
DateTime roundUpToFiveMinutes(DateTime instant) {
  final truncated = DateTime(instant.year, instant.month, instant.day,
      instant.hour, instant.minute);
  final hasRemainder = instant.isAfter(truncated);
  final minutes = truncated.minute + (hasRemainder ? 1 : 0);
  final rounded = ((minutes + 4) ~/ 5) * 5;
  return DateTime(instant.year, instant.month, instant.day, instant.hour,
      rounded);
}

/// The last layout worked out, kept in memory only, so a re-flow can leave
/// started and engaged entries where they were. [scope] names what it was
/// worked out for (the planning draft, or one session); a different scope
/// means no last layout.
class LastDayLayout {
  String? scope;
  Map<String, List<PlacedPiece>> pieces = {};

  void remember(String newScope, DayLayout layout) {
    scope = newScope;
    pieces = {for (final entry in layout.entries) entry.outcomeId: entry.pieces};
  }
}

/// A Sprint the user carried on with past a Timeboxed limit ("Another sprint,
/// regardless", or a saved raise that started the Sprint). A fact held in
/// memory only: [flowDay] makes room for it on the day.
class CarriedOnSprint {
  const CarriedOnSprint({required this.outcomeId, required this.carriedOnAt});

  final String outcomeId;

  /// When the user carried on, in local time.
  final DateTime carriedOnAt;
}

/// The pieces of [existing] with a piece added for [sprint]: one Sprint plus its
/// short break from the carry-on instant, trimmed to the part past the Outcome's
/// own pieces. Unchanged when this carry-on already has its piece or none of
/// the stretch is left. Parts are numbered in time order.
List<PlacedPiece> _withCarriedOnPiece(
  List<PlacedPiece> existing,
  CarriedOnSprint sprint,
  int chunkUnitMinutes,
) {
  if (existing.any((p) => p.carriedOnAt == sprint.carriedOnAt)) return existing;
  final stretchEnd =
      sprint.carriedOnAt.add(Duration(minutes: chunkUnitMinutes));
  // Every free stretch of [carriedOnAt, stretchEnd) outside the Outcome's own
  // pieces is reserved, so a gap before a later piece is not left for others.
  final overlapping = existing
      .where((p) =>
          p.start.isBefore(stretchEnd) && p.end.isAfter(sprint.carriedOnAt))
      .toList()
    ..sort((a, b) => a.start.compareTo(b.start));
  final freeStretches = <(DateTime, DateTime)>[];
  var cursor = sprint.carriedOnAt;
  for (final piece in overlapping) {
    if (piece.start.isAfter(cursor)) freeStretches.add((cursor, piece.start));
    if (piece.end.isAfter(cursor)) cursor = piece.end;
  }
  if (cursor.isBefore(stretchEnd)) freeStretches.add((cursor, stretchEnd));
  if (freeStretches.isEmpty) return existing;
  final all = [
    ...existing,
    for (final stretch in freeStretches)
      PlacedPiece(
        outcomeId: sprint.outcomeId,
        start: stretch.$1,
        minutes: stretch.$2.difference(stretch.$1).inMinutes,
        part: 0,
        carriedOnAt: sprint.carriedOnAt,
      ),
  ]..sort((a, b) => a.start.compareTo(b.start));
  return [
    for (var i = 0; i < all.length; i++)
      PlacedPiece(
        outcomeId: all[i].outcomeId,
        start: all[i].start,
        minutes: all[i].minutes,
        part: i + 1,
        isPinned: all[i].isPinned,
        carriedOnAt: all[i].carriedOnAt,
      ),
  ];
}

/// Works the day out.
///
/// With no last layout for [scope] the layout is rebuilt from [flowOrigin] with
/// nothing frozen. With one, it flows from [now] and freezes every placement
/// that has started before [now] and every engaged entry, so a past or engaged
/// tile never moves. The mere passing of time re-flows nothing: callers call
/// this only when an input changed.
///
/// A [carriedOn] Sprint (at or after [flowOrigin]) on an Outcome with a last
/// layout freezes that Outcome and adds a piece for the extra Sprint, so the
/// entries that are not frozen or pinned flow around it.
DayLayout flowDay({
  required String scope,
  required LastDayLayout last,
  required DateTime now,
  required DateTime flowOrigin,
  required int availableMinutes,
  required int chunkUnitMinutes,
  required List<DayTimelineEntry> entries,
  List<BusyInterval> events = const [],
  List<CarriedOnSprint> carriedOn = const [],
}) {
  final hasLast = last.scope == scope && last.pieces.isNotEmpty;
  final flowFrom = hasLast && now.isAfter(flowOrigin) ? now : flowOrigin;
  final dayEnd = flowOrigin.add(Duration(minutes: availableMinutes));

  final frozen = <String, List<PlacedPiece>>{};
  if (hasLast) {
    for (final entry in entries) {
      final pieces = last.pieces[entry.outcomeId];
      if (pieces == null || pieces.isEmpty) continue;
      final pinned = entry.pinnedStartAt;
      final firstOrdinaryPiece = pieces.firstWhere(
          (p) => p.carriedOnAt == null,
          orElse: () => pieces.first);
      if (pinned != null && pinned != firstOrdinaryPiece.start) continue;
      final entryCarriedOn = [
        for (final sprint in carriedOn)
          if (sprint.outcomeId == entry.outcomeId &&
              !sprint.carriedOnAt.isBefore(flowOrigin))
            sprint,
      ]..sort((a, b) => a.carriedOnAt.compareTo(b.carriedOnAt));
      final placedMinutes = pieces.fold<int>(0, (sum, p) => sum + p.minutes);
      final started = pieces.any((p) => p.start.isBefore(now));
      final engaged = entry.isEngaged || entryCarriedOn.isNotEmpty;
      if (!(started || engaged)) continue;
      if (placedMinutes != entry.estimateMinutes && !engaged) continue;
      var framed = pieces;
      for (final sprint in entryCarriedOn) {
        framed = _withCarriedOnPiece(framed, sprint, chunkUnitMinutes);
      }
      frozen[entry.outcomeId] = framed;
    }
  }

  final inputs = [
    for (final entry in entries)
      () {
        final interval = entry.timeContext?.allowedIntervalOn(flowOrigin);
        return PlanEntryInput(
          outcomeId: entry.outcomeId,
          estimateMinutes: entry.estimateMinutes,
          isDefaultEstimate: entry.isDefaultEstimate,
          allowedInterval: interval,
          allowedToday: entry.timeContext == null || interval != null,
          pinnedStartAt: entry.pinnedStartAt,
        );
      }(),
  ];

  final layout = autoflow(
    flowFrom: flowFrom,
    dayEnd: dayEnd,
    events: events,
    entries: inputs,
    chunkUnitMinutes: chunkUnitMinutes,
    frozen: frozen,
  );
  last.remember(scope, layout);
  return layout;
}
