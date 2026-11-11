import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  final delay = next.difference(now);
  final timer = Timer(
    delay.isNegative ? Duration.zero : delay,
    ref.invalidateSelf,
  );
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
