/// Autoflow — works out a suggested time for every entry in Today's Plan.
///
/// One pure function ([autoflow]): no Flutter, no database, no clock read. The
/// caller supplies the day window, the calendar's busy intervals and the Plan
/// entries in Plan order; the result says where each entry goes and flags the
/// ones that did not wholly fit. Every entry is in the result; none is dropped.
///
/// Order of work, so the result is deterministic:
///
/// 1. **Fixed blocks.** A pinned entry (a time the user set) is one piece at
///    its pinned start for the whole estimate; it may overlap an event and
///    ignores the Time context. Frozen placements (past or engaged) are copied
///    through unchanged. Both are obstacles for everything else.
/// 2. **Whole placement**, in Plan order: the earliest gap that holds the whole
///    estimate, inside the entry's Time context interval, not overlapping an
///    event or obstacle, and not before `flowFrom`.
/// 3. **Chunking**, for entries step 2 could not place, in Plan order, over the
///    gaps that are left: a piece is as many whole units (sprint plus short
///    break) as the gap holds; a gap that holds everything that remains takes
///    exactly the remainder, so the last piece is the short one.
library;

/// A stretch of the day that is not free (a calendar event or an obstacle).
class BusyInterval {
  const BusyInterval({required this.start, required this.end});

  final DateTime start;
  final DateTime end;

  bool overlaps(DateTime otherStart, DateTime otherEnd) =>
      start.isBefore(otherEnd) && otherStart.isBefore(end);
}

/// One Plan entry, as Autoflow needs to see it.
class PlanEntryInput {
  const PlanEntryInput({
    required this.outcomeId,
    required this.estimateMinutes,
    this.isDefaultEstimate = false,
    this.allowedInterval,
    this.allowedToday = true,
    this.pinnedStartAt,
  }) : assert(estimateMinutes > 0, 'an estimate is at least one minute');

  final String outcomeId;

  /// Minutes to place, with the default estimate already applied.
  final int estimateMinutes;

  /// Whether [estimateMinutes] is the default and not the user's own figure
  /// (the capacity bar draws the two in different tones).
  final bool isDefaultEstimate;

  /// The Time context's interval today (`TimeContext.allowedIntervalOn`), or
  /// null when the entry may go anywhere in the day.
  final ({DateTime start, DateTime end})? allowedInterval;

  /// False when the Time context allows no time today at all.
  final bool allowedToday;

  /// The time the user set; null means Jeeves places it.
  final DateTime? pinnedStartAt;
}

/// A placed stretch of an entry. An entry has one piece, or several when it
/// was chunked; [part] counts them in time order from 1.
class PlacedPiece {
  const PlacedPiece({
    required this.outcomeId,
    required this.start,
    required this.minutes,
    required this.part,
    this.isPinned = false,
    this.carriedOnAt,
  });

  final String outcomeId;
  final DateTime start;
  final int minutes;
  final int part;
  final bool isPinned;

  /// When the user carried on past a Timeboxed limit and this piece made room
  /// for the extra Sprint; null on an ordinary piece.
  final DateTime? carriedOnAt;

  DateTime get end => start.add(Duration(minutes: minutes));

  bool overlapsEvent(Iterable<BusyInterval> events) =>
      events.any((e) => e.overlaps(start, end));
}

enum PlacementStatus {
  /// One piece holds the whole estimate.
  placed,

  /// Several pieces together hold the whole estimate.
  placedInPieces,

  /// Some minutes have no gap; [EntryPlacement.unplacedMinutes] says how many.
  partlyPlaced,

  /// Nothing could be placed; [EntryPlacement.reason] says why.
  unplaced,
}

enum UnplacedReason {
  /// No gap was big enough.
  noGap,

  /// The Time context allows no time today.
  outsideTimeContext,
}

/// Where one entry went.
class EntryPlacement {
  const EntryPlacement({
    required this.outcomeId,
    required this.status,
    required this.pieces,
    required this.unplacedMinutes,
    this.reason,
  });

  final String outcomeId;
  final PlacementStatus status;
  final List<PlacedPiece> pieces;
  final int unplacedMinutes;

  /// Set when [unplacedMinutes] is above zero.
  final UnplacedReason? reason;
}

/// The figures behind the capacity bar.
class DayCapacity {
  const DayCapacity({
    required this.plannedMinutes,
    required this.defaultCountedMinutes,
    required this.freeMinutes,
  });

  /// Sum of every entry's estimate, default-counted ones included.
  final int plannedMinutes;

  /// The part of [plannedMinutes] that is the default estimate.
  final int defaultCountedMinutes;

  /// Minutes of the day window not covered by an event.
  final int freeMinutes;

  int get realMinutes => plannedMinutes - defaultCountedMinutes;

  bool get isOverbooked => plannedMinutes > freeMinutes;

  int get overByMinutes => isOverbooked ? plannedMinutes - freeMinutes : 0;

  /// Planned over free; infinite when nothing is free but something is planned.
  double get ratio => freeMinutes == 0
      ? (plannedMinutes == 0 ? 0 : double.infinity)
      : plannedMinutes / freeMinutes;
}

class DayLayout {
  const DayLayout({
    required this.entries,
    required this.events,
    required this.capacity,
  });

  /// One result per input entry, in Plan order.
  final List<EntryPlacement> entries;

  /// The busy intervals the layout was worked out around.
  final List<BusyInterval> events;

  final DayCapacity capacity;

  EntryPlacement entryFor(String outcomeId) =>
      entries.firstWhere((e) => e.outcomeId == outcomeId);
}

/// Lays [entries] out over the window [flowFrom]..[dayEnd] around [events].
///
/// [chunkUnitMinutes] is sprint length plus short break. [frozen] maps an
/// Outcome id to placements that must not move; such an entry is copied
/// through and not placed again.
DayLayout autoflow({
  required DateTime flowFrom,
  required DateTime dayEnd,
  required List<BusyInterval> events,
  required List<PlanEntryInput> entries,
  required int chunkUnitMinutes,
  Map<String, List<PlacedPiece>> frozen = const {},
}) {
  assert(chunkUnitMinutes > 0);
  final busy = <BusyInterval>[...events];
  final results = <String, EntryPlacement>{};

  EntryPlacement fromPieces(PlanEntryInput entry, List<PlacedPiece> pieces) {
    final placedMinutes = pieces.fold<int>(0, (sum, p) => sum + p.minutes);
    final missing = entry.estimateMinutes - placedMinutes;
    final PlacementStatus status;
    if (pieces.isEmpty) {
      status = PlacementStatus.unplaced;
    } else if (missing > 0) {
      status = PlacementStatus.partlyPlaced;
    } else if (pieces.length > 1) {
      status = PlacementStatus.placedInPieces;
    } else {
      status = PlacementStatus.placed;
    }
    return EntryPlacement(
      outcomeId: entry.outcomeId,
      status: status,
      pieces: List.unmodifiable(pieces),
      unplacedMinutes: missing > 0 ? missing : 0,
      reason: missing > 0 ? UnplacedReason.noGap : null,
    );
  }

  // 1. Fixed blocks: frozen placements, then pinned entries.
  for (final entry in entries) {
    final frozenPieces = frozen[entry.outcomeId];
    final pinnedStart = entry.pinnedStartAt;
    if (frozenPieces != null && frozenPieces.isNotEmpty) {
      results[entry.outcomeId] = fromPieces(entry, frozenPieces);
      for (final piece in frozenPieces) {
        busy.add(BusyInterval(start: piece.start, end: piece.end));
      }
    } else if (pinnedStart != null) {
      final piece = PlacedPiece(
        outcomeId: entry.outcomeId,
        start: pinnedStart,
        minutes: entry.estimateMinutes,
        part: 1,
        isPinned: true,
      );
      results[entry.outcomeId] = fromPieces(entry, [piece]);
      busy.add(BusyInterval(start: piece.start, end: piece.end));
    }
  }

  List<BusyInterval> gapsFor(PlanEntryInput entry) {
    final allowed = entry.allowedInterval;
    final lower = allowed != null && allowed.start.isAfter(flowFrom)
        ? allowed.start
        : flowFrom;
    final upper =
        allowed != null && allowed.end.isBefore(dayEnd) ? allowed.end : dayEnd;
    return _freeGaps(lower, upper, busy);
  }

  int minutesIn(BusyInterval gap) => gap.end.difference(gap.start).inMinutes;

  // 2. Whole placement, in Plan order.
  final needChunking = <PlanEntryInput>[];
  for (final entry in entries) {
    if (results.containsKey(entry.outcomeId)) continue;
    if (!entry.allowedToday) {
      results[entry.outcomeId] = EntryPlacement(
        outcomeId: entry.outcomeId,
        status: PlacementStatus.unplaced,
        pieces: const [],
        unplacedMinutes: entry.estimateMinutes,
        reason: UnplacedReason.outsideTimeContext,
      );
      continue;
    }
    BusyInterval? fit;
    for (final gap in gapsFor(entry)) {
      if (minutesIn(gap) >= entry.estimateMinutes) {
        fit = gap;
        break;
      }
    }
    if (fit == null) {
      needChunking.add(entry);
      continue;
    }
    final piece = PlacedPiece(
      outcomeId: entry.outcomeId,
      start: fit.start,
      minutes: entry.estimateMinutes,
      part: 1,
    );
    results[entry.outcomeId] = fromPieces(entry, [piece]);
    busy.add(BusyInterval(start: piece.start, end: piece.end));
  }

  // 3. Chunking, in Plan order, over the gaps that are left.
  for (final entry in needChunking) {
    var remaining = entry.estimateMinutes;
    final pieces = <PlacedPiece>[];
    for (final gap in gapsFor(entry)) {
      if (remaining <= 0) break;
      final gapMinutes = minutesIn(gap);
      final int pieceMinutes;
      if (gapMinutes >= remaining) {
        pieceMinutes = remaining;
      } else {
        pieceMinutes = (gapMinutes ~/ chunkUnitMinutes) * chunkUnitMinutes;
      }
      if (pieceMinutes <= 0) continue;
      pieces.add(PlacedPiece(
        outcomeId: entry.outcomeId,
        start: gap.start,
        minutes: pieceMinutes,
        part: pieces.length + 1,
      ));
      remaining -= pieceMinutes;
    }
    for (final piece in pieces) {
      busy.add(BusyInterval(start: piece.start, end: piece.end));
    }
    results[entry.outcomeId] = fromPieces(entry, pieces);
  }

  var planned = 0;
  var defaultCounted = 0;
  for (final entry in entries) {
    planned += entry.estimateMinutes;
    if (entry.isDefaultEstimate) defaultCounted += entry.estimateMinutes;
  }
  final freeMinutes = _freeGaps(flowFrom, dayEnd, events)
      .fold<int>(0, (sum, gap) => sum + minutesIn(gap));

  return DayLayout(
    entries: [for (final entry in entries) results[entry.outcomeId]!],
    events: List.unmodifiable(events),
    capacity: DayCapacity(
      plannedMinutes: planned,
      defaultCountedMinutes: defaultCounted,
      freeMinutes: freeMinutes,
    ),
  );
}

/// The stretches of [lower]..[upper] that no interval in [busy] covers, in time
/// order. Empty when the window is empty.
List<BusyInterval> freeGaps(
        DateTime lower, DateTime upper, List<BusyInterval> busy) =>
    _freeGaps(lower, upper, busy);

List<BusyInterval> _freeGaps(
    DateTime lower, DateTime upper, List<BusyInterval> busy) {
  final gaps = <BusyInterval>[];
  if (!lower.isBefore(upper)) return gaps;
  final sorted = [...busy]..sort((a, b) => a.start.compareTo(b.start));
  var cursor = lower;
  for (final interval in sorted) {
    if (!cursor.isBefore(upper)) break;
    if (interval.start.isAfter(cursor)) {
      final gapEnd = interval.start.isBefore(upper) ? interval.start : upper;
      gaps.add(BusyInterval(start: cursor, end: gapEnd));
    }
    if (interval.end.isAfter(cursor)) cursor = interval.end;
  }
  if (cursor.isBefore(upper)) {
    gaps.add(BusyInterval(start: cursor, end: upper));
  }
  return gaps;
}
