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
  /// on, so the limit can be reached inside it.
  final String? endedAt;
}

/// The instant the limit passed, or null when it has not.
///
/// [intervals] are the Action's TimeLogs in any order — they are walked in
/// start order here. A stint that ends before it starts (clock skew) counts
/// for nothing. An open stint counts as running on, so the answer can be an
/// instant in the future.
DateTime? limitPassedAt(int limitMinutes, List<TimeLogInterval> intervals) {
  if (intervals.isEmpty) return null;
  final limit = Duration(minutes: limitMinutes);
  final ordered = <({TimeLogInterval interval, DateTime startedAt})>[];
  for (final interval in intervals) {
    final startedAt = _parseInstant(interval.startedAt);
    if (startedAt == null) continue;
    ordered.add((interval: interval, startedAt: startedAt));
  }
  ordered.sort((a, b) => a.startedAt.compareTo(b.startedAt));

  var logged = Duration.zero;
  for (final entry in ordered) {
    final startedAt = entry.startedAt;
    final endedAt = _parseInstant(entry.interval.endedAt);
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

/// Parses a stored instant; null for an absent or unparseable value.
DateTime? _parseInstant(String? value) {
  if (value == null) return null;
  return DateTime.tryParse(value)?.toUtc();
}
