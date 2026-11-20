/// The small-task suggestion (issue #407): two or more small Plan entries that
/// share a context and fit together in one free gap.
///
/// Pure functions over the day timeline's inputs: no Flutter, no database, no
/// clock read. The same inputs always give the same suggestion, so it never
/// flickers while only time passes.
library;

import 'autoflow.dart';
import 'day_timeline.dart';

/// The largest estimate a member of a suggestion may have, in minutes.
const int batchMemberMaxMinutes = 10;

/// One suggested member: an Outcome, when it would start and how long it takes.
typedef BatchMember = ({String outcomeId, DateTime start, int minutes});

class BatchSuggestion {
  const BatchSuggestion({
    required this.contextTagId,
    required this.contextName,
    required this.gapStart,
    required this.gapEnd,
    required this.members,
  });

  final String contextTagId;
  final String contextName;

  /// The free gap the members go in, start and end.
  final DateTime gapStart;
  final DateTime gapEnd;

  /// Back to back from [gapStart], in Plan order.
  final List<BatchMember> members;

  int get totalMinutes => members.fold(0, (sum, member) => sum + member.minutes);
}

/// Whether [entry] may be offered in a suggestion: it has a context, a user
/// estimate of at most [maxMemberMinutes], and nothing the user or the day has
/// already decided about it.
bool isBatchCandidate(DayTimelineEntry entry,
    {int maxMemberMinutes = batchMemberMaxMinutes}) {
  return !entry.isDone &&
      !entry.isRunning &&
      !entry.isEngaged &&
      entry.pinnedStartAt == null &&
      entry.batchId == null &&
      !entry.isBatchSuggestionDeclined &&
      !entry.isDefaultEstimate &&
      entry.estimateMinutes <= maxMemberMinutes &&
      entry.timeContext == null &&
      entry.contextTags.isNotEmpty;
}

/// The next suggestion, or null when no context has two or more candidates that
/// fit together in a free gap.
///
/// Candidates are grouped by context tag. Groups are ordered by the Plan
/// position of their first candidate, and a candidate with several contexts
/// belongs to the first group that uses it. For each group, the free gaps from
/// [flowFrom] (rounded up to five minutes) to [dayEnd] are tried in time order;
/// a gap is free of events and of every placed tile except the group's own
/// candidates'. In a gap the group's candidates are taken in Plan order, one that
/// no longer fits being passed over. The first gap that takes two or more gives
/// the suggestion; the first group that has one wins.
BatchSuggestion? nextBatchSuggestion({
  required List<DayTimelineEntry> entries,
  required DayLayout layout,
  required DateTime flowFrom,
  required DateTime dayEnd,
  int maxMemberMinutes = batchMemberMaxMinutes,
}) {
  final candidates = [
    for (final entry in entries)
      if (isBatchCandidate(entry, maxMemberMinutes: maxMemberMinutes)) entry,
  ];
  if (candidates.length < 2) return null;

  // Groups in the order their first candidate appears.
  final groupOrder = <String>[];
  final groupNames = <String, String>{};
  for (final entry in candidates) {
    for (final tag in entry.contextTags) {
      if (groupNames.containsKey(tag.id)) continue;
      groupNames[tag.id] = tag.name;
      groupOrder.add(tag.id);
    }
  }
  final groups = <String, List<DayTimelineEntry>>{};
  for (final entry in candidates) {
    final owner = groupOrder.firstWhere(
        (id) => entry.contextTags.any((tag) => tag.id == id));
    (groups[owner] ??= []).add(entry);
  }

  final lower = roundUpToFiveMinutes(flowFrom);
  for (final tagId in groupOrder) {
    final group = groups[tagId];
    if (group == null || group.length < 2) continue;
    final groupIds = {for (final entry in group) entry.outcomeId};
    final busy = <BusyInterval>[
      ...layout.events,
      for (final placement in layout.entries)
        if (!groupIds.contains(placement.outcomeId))
          for (final piece in placement.pieces)
            BusyInterval(start: piece.start, end: piece.end),
    ];
    for (final gap in freeGaps(lower, dayEnd, busy)) {
      final gapMinutes = gap.end.difference(gap.start).inMinutes;
      final taken = <DayTimelineEntry>[];
      var usedMinutes = 0;
      for (final entry in group) {
        if (usedMinutes + entry.estimateMinutes > gapMinutes) continue;
        taken.add(entry);
        usedMinutes += entry.estimateMinutes;
      }
      if (taken.length < 2) continue;
      final starts = batchMemberStarts(gap.start, taken);
      return BatchSuggestion(
        contextTagId: tagId,
        contextName: groupNames[tagId]!,
        gapStart: gap.start,
        gapEnd: gap.end,
        members: [
          for (final entry in taken)
            (
              outcomeId: entry.outcomeId,
              start: starts[entry.outcomeId]!,
              minutes: entry.estimateMinutes,
            ),
        ],
      );
    }
  }
  return null;
}

/// The candidates of [suggestion]'s context that are not yet members: what the
/// Edit sheet may offer to add. The sheet decides whether one still fits.
List<DayTimelineEntry> batchAddable({
  required List<DayTimelineEntry> entries,
  required BatchSuggestion suggestion,
  int maxMemberMinutes = batchMemberMaxMinutes,
}) {
  final memberIds = {for (final member in suggestion.members) member.outcomeId};
  return [
    for (final entry in entries)
      if (!memberIds.contains(entry.outcomeId) &&
          isBatchCandidate(entry, maxMemberMinutes: maxMemberMinutes) &&
          entry.contextTags.any((tag) => tag.id == suggestion.contextTagId))
        entry,
  ];
}

/// Each of [members] starts when the one before ends, the first at [gapStart].
Map<String, DateTime> batchMemberStarts(
    DateTime gapStart, List<DayTimelineEntry> members) {
  final starts = <String, DateTime>{};
  var cursor = gapStart;
  for (final member in members) {
    starts[member.outcomeId] = cursor;
    cursor = cursor.add(Duration(minutes: member.estimateMinutes));
  }
  return starts;
}
