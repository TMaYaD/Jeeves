import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/time_context_tag_conversion.dart';
import '../models/time_context.dart';
import 'clock_provider.dart';
import 'database_provider.dart';

/// Parsed TimeContext of every Outcome's current Action, keyed by Outcome id
/// (issue #238). Outcomes without one, or whose stored value does not parse,
/// are absent.
final currentTimeContextsProvider =
    StreamProvider<Map<String, TimeContext>>((ref) {
  return ref.watch(databaseProvider).actionDao.watchCurrentTimeContexts();
});

/// Longest delay the boundary timer is armed with. Browsers store a timer
/// delay as a 32-bit signed millisecond count (about 24.8 days), so a longer
/// delay wraps and fires at once. A capped timer that fires early just
/// rebuilds the provider, which re-arms it.
const Duration maxBoundaryTimerDelay = Duration(days: 1);

/// Delay to arm the boundary timer with for [next], never negative and never
/// above [maxBoundaryTimerDelay].
Duration boundaryTimerDelay(DateTime now, DateTime next) {
  final delay = next.difference(now);
  if (delay.isNegative) return Duration.zero;
  return delay > maxBoundaryTimerDelay ? maxBoundaryTimerDelay : delay;
}

/// A coarse signal that advances whenever a TimeContext flips between
/// satisfied and unsatisfied. Arms one [Timer] at the earliest
/// [TimeContext.nextTransitionAfter] over [currentTimeContextsProvider] and
/// re-arms on every rebuild — the same shape as `nudgeBoundaryTickProvider`.
///
/// The gate below evaluates against the clock on every rebuild, so a late timer
/// (app backgrounded) only delays the refresh; it never shows wrong data.
final timeContextBoundaryTickProvider = Provider<int>((ref) {
  final now = ref.watch(clockProvider)();
  final contexts =
      ref.watch(currentTimeContextsProvider).value ?? const {};
  DateTime? next;
  for (final tc in contexts.values) {
    final t = tc.nextTransitionAfter(now);
    if (t != null && (next == null || t.isBefore(next))) next = t;
  }
  if (next == null) return 0;
  final timer = Timer(boundaryTimerDelay(now, next), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return next.millisecondsSinceEpoch ~/ 1000;
});

/// Outcome ids whose current Action's TimeContext is not satisfied right now.
/// The Next List and Daily Planning's Up Next hide these; every other surface
/// ignores this set (the Outcome stays on Next, only the surfaces hide it).
final outsideTimeContextOutcomeIdsProvider = Provider<Set<String>>((ref) {
  ref.watch(timeContextBoundaryTickProvider);
  final now = ref.watch(clockProvider)();
  final contexts =
      ref.watch(currentTimeContextsProvider).value ?? const {};
  return {
    for (final e in contexts.entries)
      if (!e.value.isSatisfiedAt(now)) e.key,
  };
});

/// Converts time-named context tags into TimeContexts, once per store, until a
/// device-local completion marker exists (issue #238). Eagerly watched from
/// `main.dart`.
///
/// Gated on the marker, not on the schema version: the schema upgrade commits
/// before the conversion, so a process stopped between the two would otherwise
/// skip the conversion for good. The marker is written in the conversion's own
/// transaction; fresh installs get it at creation. Ordered after
/// [domainStoreRebuildProvider] so the post-upgrade re-projection cannot
/// re-project a link the conversion just removed. A failure rethrows into the
/// provider's error state; the transaction leaves all or nothing done.
final FutureProvider<int> timeContextTagConversionProvider =
    FutureProvider<int>((ref) async {
  ref.keepAlive();
  await ref.read(domainStoreRebuildProvider.future);
  final db = ref.read(databaseProvider);
  try {
    return await convertTimeNamedContextTags(db);
  } on Object catch (error) {
    debugPrint('time context tag conversion: failed — $error');
    rethrow;
  }
});
