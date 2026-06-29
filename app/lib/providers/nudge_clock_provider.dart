/// The reactive wall-clock seam for the Nudge module's time-based Triggers.
///
/// Time-based Trigger predicates (see `nudge_triggers.dart`) compare the
/// current instant against scheduled boundaries — the day boundary, the
/// Evening Shutdown anchor, the Weekly Review cadence-due instant. Sampling
/// `DateTime.now()` directly inside those Providers makes them un-reactive:
/// Riverpod never re-evaluates them when a boundary passes, so a predicate's
/// false→true edge is only observed when some unrelated rebuild happens to
/// re-run the Provider.
///
/// This builds on the shared [clockProvider] (the overridable "what time is it"
/// seam in `clock_provider.dart`) and adds:
///
/// - [nudgeBoundaryTickProvider] — a coarse reactive signal that the
///   time-based Trigger Providers `ref.watch`. It schedules a single [Timer]
///   that fires at the *next* relevant boundary across all Rituals (next day
///   boundary, today's Evening Shutdown anchor, the Weekly Review due instant),
///   bumps the tick, and re-arms. Watching it re-evaluates a Trigger exactly
///   when a boundary crosses — not on a per-second cadence — so there is no
///   rebuild storm and unrelated Providers are untouched.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'clock_provider.dart';
import 'periodic_review_settings_provider.dart'
    show periodicReviewLastCompletedProvider;
import 'shutdown_settings_provider.dart' show shutdownSettingsProvider;

// ---------------------------------------------------------------------------
// Boundary scheduling
// ---------------------------------------------------------------------------

/// Cadence period for the Weekly Review, mirrored from
/// `periodic_review_settings_provider.dart`. Kept here so the boundary
/// computation can locate the next cadence-due instant without reaching into
/// that file's private constant.
const int _kWeeklyReviewCadenceDays = 7;

/// Start of the local day containing [now] (midnight).
DateTime _startOfDay(DateTime now) => DateTime(now.year, now.month, now.day);

/// The next local day boundary strictly after [now].
// Uses the local-time constructor (`day + 1`) rather than `add(Duration(days:
// 1))` so the boundary lands on the next calendar midnight even across a DST
// transition, where a "day" is not a fixed 24 hours.
DateTime _nextDayBoundary(DateTime now) =>
    DateTime(now.year, now.month, now.day + 1);

/// Today's local instant of [hour]:[minute].
DateTime _todayAt(DateTime now, int hour, int minute) {
  final today = _startOfDay(now);
  return DateTime(today.year, today.month, today.day, hour, minute);
}

/// The earliest boundary strictly after [now] across all Rituals' time-based
/// Trigger predicates. This is the instant at which at least one predicate
/// *could* change truth value purely because the clock advanced — so it is the
/// instant the reactive tick must next fire.
///
/// Boundaries considered:
///   - the next day boundary (DPR / WR `firingSince` and the content-state
///     per-day stamp all key off start-of-day);
///   - today's Evening Shutdown anchor, if still in the future (ES flips at it);
///   - the Weekly Review cadence-due instant (`lastCompleted + 7d`), if still
///     in the future (WR's due predicate flips at it).
DateTime nextNudgeBoundary(
  DateTime now, {
  required int shutdownHour,
  required int shutdownMinute,
  required DateTime? weeklyReviewLastCompleted,
}) {
  var next = _nextDayBoundary(now);

  final shutdownAnchor = _todayAt(now, shutdownHour, shutdownMinute);
  if (shutdownAnchor.isAfter(now) && shutdownAnchor.isBefore(next)) {
    next = shutdownAnchor;
  }

  if (weeklyReviewLastCompleted != null) {
    final due = weeklyReviewLastCompleted
        .add(const Duration(days: _kWeeklyReviewCadenceDays));
    if (due.isAfter(now) && due.isBefore(next)) {
      next = due;
    }
  }

  return next;
}

/// A coarse reactive signal that time-based Trigger Providers `ref.watch` so
/// they re-evaluate when a wall-clock boundary passes.
///
/// On each build it computes [nextNudgeBoundary] from the current clock and the
/// boundary-relevant settings ([shutdownSettingsProvider],
/// [periodicReviewLastCompletedProvider]) it watches, then schedules a single
/// [Timer] to [Ref.invalidateSelf] at that instant. Re-building recomputes the
/// next boundary and re-arms — so exactly one timer is ever pending, and it
/// fires once per boundary rather than once per tick. When a watched setting
/// changes (e.g. the user moves their shutdown time), the Provider rebuilds and
/// the timer re-targets the new boundary.
///
/// The returned value is the epoch-second of the boundary currently being
/// waited on. It changes whenever the target boundary changes (a day rollover,
/// or an intra-day re-arm onto the shutdown / review boundary), so downstream
/// `ref.watch`ers observe a value change and re-run. Its magnitude is not
/// meaningful — only that it advances.
final nudgeBoundaryTickProvider = Provider<int>((ref) {
  final now = ref.watch(clockProvider)();
  final shutdown = ref.watch(shutdownSettingsProvider).shutdownTime;
  final lastReview = ref.watch(periodicReviewLastCompletedProvider);

  final next = nextNudgeBoundary(
    now,
    shutdownHour: shutdown.hour,
    shutdownMinute: shutdown.minute,
    weeklyReviewLastCompleted: lastReview,
  );

  final delay = next.difference(now);
  // Clamp to a non-negative delay; a zero/negative computed boundary (clock
  // skew, or a boundary that just passed) fires on the next event-loop turn.
  final timer = Timer(
    delay.isNegative ? Duration.zero : delay,
    ref.invalidateSelf,
  );
  ref.onDispose(timer.cancel);

  return next.millisecondsSinceEpoch ~/ 1000;
});
