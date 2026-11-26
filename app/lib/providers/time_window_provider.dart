import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/time_window_dao.dart';
import '../database/gtd_database.dart' show TimeWindow;
import '../models/action_place_and_time_window.dart';
import 'clock_provider.dart';
import 'database_provider.dart';
import 'time_context_provider.dart';

/// The user's named time windows, in name order.
final timeWindowsProvider = StreamProvider<List<TimeWindow>>((ref) {
  return ref.watch(databaseProvider).timeWindowDao.watchTimeWindows();
});

/// The user's named time windows, each with the number of current Actions of
/// active Outcomes that use it (issue #55).
final timeWindowsWithUseCountProvider =
    StreamProvider<List<TimeWindowWithCount>>((ref) {
  return ref
      .watch(databaseProvider)
      .timeWindowDao
      .watchTimeWindowsWithUseCount();
});

/// The named time window of every Outcome's current Action, keyed by Outcome id
/// (issue #55).
///
/// An Outcome whose current Action carries no window, or names a window that
/// no longer exists, or names one whose hours the app cannot read, is absent —
/// an unreadable window never hides an Outcome.
final currentTimeWindowsProvider =
    StreamProvider<Map<String, ActionTimeWindow>>((ref) {
  return ref.watch(databaseProvider).actionDao.watchCurrentTimeWindows();
});

/// A coarse signal that advances whenever a named window may have flipped
/// between open and closed. Arms one [Timer] at the earliest
/// [TimeWindowHours.nextTransitionAfter] over [currentTimeWindowsProvider] and
/// re-arms on every rebuild — the same shape as the Time context's boundary
/// tick.
///
/// The signal counts the re-reads rather than naming the next boundary. The
/// same instant can be the next boundary twice over: a phone that changed its
/// time zone while the app was away can leave a window's opening and its
/// closing on one instant. Riverpod only wakes a dependent when the value it
/// watches changes — it filters equal values — so a signal that repeated
/// would leave the set of hidden Outcomes as it was.
///
/// The gate below evaluates against the clock on every rebuild, so a late
/// timer (app backgrounded) only delays the refresh; it never shows wrong data.
final timeWindowBoundaryTickProvider =
    NotifierProvider<TimeWindowBoundaryTick, int>(TimeWindowBoundaryTick.new);

class TimeWindowBoundaryTick extends Notifier<int> {
  /// How many times the windows have been read. It only grows, so every
  /// re-read is a new value and every dependent re-reads the windows with it.
  int _reads = 0;

  @override
  int build() {
    final now = ref.watch(clockProvider)();
    final windows = ref.watch(currentTimeWindowsProvider).value ?? const {};
    DateTime? next;
    for (final window in windows.values) {
      final t = window.hours.nextTransitionAfter(now);
      if (t != null && (next == null || t.isBefore(next))) next = t;
    }
    if (next != null) {
      final timer = Timer(boundaryTimerDelay(now, next), ref.invalidateSelf);
      ref.onDispose(timer.cancel);
    }
    _reads++;
    return _reads;
  }
}

/// Outcome ids whose current Action's named time window is closed right now.
///
/// The Next List hides these. Daily Planning's Up Next applies its own rule —
/// the day being planned — so a window that opens later today keeps the
/// Outcome in Up Next.
final outsideTimeWindowOutcomeIdsProvider = Provider<Set<String>>((ref) {
  ref.watch(timeWindowBoundaryTickProvider);
  final now = ref.watch(clockProvider)();
  final windows = ref.watch(currentTimeWindowsProvider).value ?? const {};
  return {
    for (final e in windows.entries)
      if (!e.value.hours.isOpenAt(now)) e.key,
  };
});

/// Re-arms the time boundary when the app comes back to the foreground.
///
/// A phone can change its time zone while Jeeves is in the background, and a
/// Time context and a named window are both wall-clock: the flip that mattered
/// may have happened while the app was away. Both boundary ticks are armed
/// against the clock as it was when they were built, so a resume invalidates
/// them and the flip applies.
///
/// Eagerly watched from `main.dart`: nothing else reads it, so without that
/// watch it would never run.
final timeBoundaryResumeProvider = Provider<int>((ref) {
  final observer = _TimeBoundaryResumeObserver(() {
    ref.invalidate(timeContextBoundaryTickProvider);
    ref.invalidate(timeWindowBoundaryTickProvider);
  });
  WidgetsBinding.instance.addObserver(observer);
  ref.onDispose(() => WidgetsBinding.instance.removeObserver(observer));
  return 0;
});

class _TimeBoundaryResumeObserver with WidgetsBindingObserver {
  _TimeBoundaryResumeObserver(this._onResumed);

  final void Function() _onResumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _onResumed();
  }
}
