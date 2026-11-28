/// When a Timeboxed Action's limit passed.
///
/// The limit is measured against **all time logged on the Action**, breaks
/// included, across sessions and days — the reading the design page takes
/// ("logged 1h 22m" is the limit plus the 22 minutes past). Nothing is stored:
/// the instant is derived from the Action's TimeLogs, so every device holding
/// the same logs agrees on it, and raising the estimate moves it with no second
/// write.
///
/// A pure function, so the whole rule is one readable place: the only thing a
/// caller has to decide is *which* stints count, and that answer lives in the
/// list it hands over.
library;

/// One stint of logged time, as the store holds it: raw timestamp text.
///
/// The text is parsed here rather than by the caller, so a row whose timestamp
/// does not parse is skipped instead of failing the whole read.
class TimeLogInterval {
  const TimeLogInterval({required this.startedAt, this.endedAt});

  /// The stint's start, as stored. Null, or unparseable, means the stint is
  /// skipped.
  final String? startedAt;

  /// The stint's end, as stored. Null means the stint is still open: it runs
  /// on, so the limit can be reached inside it. An end that does not parse is
  /// read the same way — the stint runs on rather than counting for a length
  /// nobody can read.
  final String? endedAt;
}

/// The instant the limit passed, or null when it has not.
///
/// [intervals] are the Action's TimeLogs in any order — they are walked in
/// start order here. A stint that ends before it starts (clock skew) counts
/// for nothing. An open stint counts as running on, so the answer can be an
/// instant in the future.
///
/// Two stints that start together are read in a fixed order — the one that
/// ends first, and a stint that is still open last — so the answer does not
/// depend on the order the stints arrive in. Dart's sort does not promise to
/// keep equal elements where they were, and two devices that read the same
/// stints in different orders would disagree about the instant the limit
/// passed.
DateTime? limitPassedAt(int limitMinutes, List<TimeLogInterval> intervals) {
  if (intervals.isEmpty) return null;
  final limit = Duration(minutes: limitMinutes);
  final ordered = _orderedStints(intervals);

  var logged = Duration.zero;
  for (final entry in ordered) {
    final startedAt = entry.startedAt;
    final endedAt = entry.endedAt;
    if (endedAt == null) {
      // Still open: it runs on, so the limit is reached inside it — which may
      // be an instant that has not arrived yet.
      return startedAt.add(limit - logged);
    }
    final length = endedAt.difference(startedAt);
    if (length.isNegative) continue;
    if (logged + length >= limit) {
      return startedAt.add(limit - logged);
    }
    logged += length;
  }
  return null;
}

/// The time logged on an Action by [now] — every stint, breaks included.
///
/// The same reading [limitPassedAt] reads it: the same stints, the same skips,
/// an open stint counted on to [now]. The two therefore cannot disagree — for
/// any value V, V minutes is more than the time logged exactly when the limit
/// of V minutes has not passed by [now].
///
/// The walk stops at the first stint that is still open, as it does in
/// [limitPassedAt]: a stint that is still running is the end of the story,
/// and the work logged after it cannot be counted without counting the run
/// twice.
Duration loggedDurationOn(List<TimeLogInterval> intervals, DateTime now) {
  var logged = Duration.zero;
  for (final entry in _orderedStints(intervals)) {
    final endedAt = entry.endedAt;
    if (endedAt == null) {
      // Still open: it runs on, so the time logged grows with the clock.
      final running = now.toUtc().difference(entry.startedAt);
      if (!running.isNegative) logged += running;
      break;
    }
    final length = endedAt.difference(entry.startedAt);
    if (length.isNegative) continue;
    logged += length;
  }
  return logged;
}

/// Parses a stored instant; null for an absent or unparseable value.
DateTime? _parseInstant(String? value) {
  if (value == null) return null;
  return DateTime.tryParse(value)?.toUtc();
}

/// The stints, in the order they are read: by start, then by end.
///
/// The order is fixed so that the answer does not depend on the order the
/// stints arrive in. Dart's sort does not promise to keep equal elements
/// where they were, and two devices that read the same stints in different
/// orders would disagree about the instant the limit passed.
List<({DateTime startedAt, DateTime? endedAt})> _orderedStints(
  List<TimeLogInterval> intervals,
) {
  final ordered = <({DateTime startedAt, DateTime? endedAt})>[];
  for (final interval in intervals) {
    final startedAt = _parseInstant(interval.startedAt);
    if (startedAt == null) continue;
    ordered.add((
      startedAt: startedAt,
      endedAt: _parseInstant(interval.endedAt),
    ));
  }
  ordered.sort((a, b) {
    final byStart = a.startedAt.compareTo(b.startedAt);
    if (byStart != 0) return byStart;
    // The same start: the stint that ends first is read first, and a stint
    // that is still open — it runs on — is read last.
    final aEnd = a.endedAt;
    final bEnd = b.endedAt;
    if (aEnd == null) return bEnd == null ? 0 : 1;
    if (bEnd == null) return -1;
    return aEnd.compareTo(bEnd);
  });
  return ordered;
}
