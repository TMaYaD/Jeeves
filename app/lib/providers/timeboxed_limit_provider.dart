/// The limit status of a Timeboxed Action (issue #923).
///
/// Everything here is derived at read time from synced data — the Action's
/// estimate, its TimeLogs and the Sprints recorded against it — so a device
/// that has the rows agrees with every other device that has them, and
/// raising the estimate moves the limit with no second write.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../models/timeboxed.dart';
import '../utils/timeboxed_limit.dart';
import 'database_provider.dart';

/// The limit status of [outcomeId]'s current Action, live.
///
/// Null when the Outcome is not Timeboxed — which is what keeps every surface
/// that reads this silent for a plain estimate.
final timeboxedLimitStatusProvider =
    StreamProvider.autoDispose.family<TimeboxedLimitStatus?, String>(
  (ref, outcomeId) {
    final db = ref.watch(databaseProvider);
    return db.actionDao.watchCurrentAction(outcomeId).asyncExpand((action) {
      if (action == null) {
        return Stream<TimeboxedLimitStatus?>.value(null);
      }
      final limit = action.timeEstimate;
      if (!isTimeboxedAction(
        timeboxed: action.timeboxed,
        timeEstimate: limit,
      )) {
        return Stream<TimeboxedLimitStatus?>.value(null);
      }
      final logs = (db.select(db.timeLogs)
            ..where((t) => t.actionId.equals(action.id)))
          .watch();
      final sprints = (db.select(db.sprints)
            ..where((s) => s.actionId.equals(action.id)))
          .watch();
      return _combineLatest(
        logs,
        sprints,
        (logRows, sprintRows) => _status(
          limitMinutes: limit!,
          logs: logRows,
          sprints: sprintRows,
        ),
      );
    });
  },
);

/// Which Outcomes currently have a Timeboxed Action, live.
///
/// A map of Outcome id to whether that Outcome's current Action is Timeboxed.
/// Used by the Focus list, where a row must show the mark without asking for
/// each Outcome's Action one at a time.
final currentTimeboxedProvider =
    StreamProvider.autoDispose<Map<String, bool>>((ref) {
  return ref.watch(databaseProvider).actionDao.watchCurrentTimeboxed();
});

/// The status of one Timeboxed Action, from its stints and its Sprints.
TimeboxedLimitStatus _status({
  required int limitMinutes,
  required List<TimeLog> logs,
  required List<Sprint> sprints,
}) {
  final passed = limitPassedAt(limitMinutes, [
    for (final log in logs)
      TimeLogInterval(startedAt: log.startedAt, endedAt: log.endedAt),
  ]);
  final starts = <DateTime>[];
  for (final sprint in sprints) {
    final startedAt = DateTime.tryParse(sprint.startedAt)?.toUtc();
    if (startedAt == null) continue;
    starts.add(startedAt);
  }
  starts.sort();
  var before = 0;
  var past = 0;
  for (final start in starts) {
    if (passed != null && !start.isBefore(passed)) {
      past++;
    } else {
      before++;
    }
  }
  return TimeboxedLimitStatus(
    limitMinutes: limitMinutes,
    limitPassedAt: passed,
    sprintsBeforeLimit: before,
    sprintsPastLimit: past,
    sprintStarts: List.unmodifiable(starts),
  );
}

/// Emits whenever either source emits, combining the latest value of each.
///
/// Hand-rolled rather than pulling in rxdart for a single call site: the two
/// legs are independent Drift streams that must both stay live, and neither
/// emits on a fixed schedule.
Stream<R> _combineLatest<A, B, R>(
  Stream<A> a,
  Stream<B> b,
  R Function(A, B) combine,
) {
  late StreamController<R> controller;
  StreamSubscription<A>? subA;
  StreamSubscription<B>? subB;
  late A latestA;
  late B latestB;
  var hasA = false;
  var hasB = false;

  void emit() {
    if (hasA && hasB) controller.add(combine(latestA, latestB));
  }

  controller = StreamController<R>(
    onListen: () {
      subA = a.listen(
        (v) {
          latestA = v;
          hasA = true;
          emit();
        },
        onError: controller.addError,
      );
      subB = b.listen(
        (v) {
          latestB = v;
          hasB = true;
          emit();
        },
        onError: controller.addError,
      );
    },
    onCancel: () async {
      await subA?.cancel();
      await subB?.cancel();
    },
  );

  return controller.stream;
}
