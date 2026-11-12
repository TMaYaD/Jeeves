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

/// Converts time-named context tags into TimeContexts, once, on the first launch
/// after the v4 schema upgrade (issue #238). Eagerly watched from `main.dart`.
///
/// Ordered after [domainStoreRebuildProvider] so the post-upgrade re-projection
/// cannot re-project a link the conversion just removed. Fresh installs have no
/// tags to convert. A failure rethrows into the provider's error state (the
/// rebuild provider's convention); the transaction leaves all or nothing done.
final FutureProvider<int> timeContextTagConversionProvider =
    FutureProvider<int>((ref) async {
  ref.keepAlive();
  await ref.read(domainStoreRebuildProvider.future);
  final db = ref.read(databaseProvider);
  // Force the delayed connection open (and its migration) before reading the
  // verdict, as [domainStoreRebuildProvider] does.
  await db.customSelect('SELECT 1').getSingle();
  final details = await db.opened;
  final before = details.versionBefore;
  if (before == null || before >= 4) return 0;
  try {
    return await convertTimeNamedContextTags(db);
  } on Object catch (error) {
    debugPrint('time context tag conversion: failed — $error');
    rethrow;
  }
});
