/// The limit status of a Timeboxed Action (issue #923).
///
/// Everything here is derived at read time from synced data — the Action's
/// estimate, its TimeLogs and the Sprints recorded against it — so a device
/// that has the rows agrees with every other device that has them, and
/// raising the estimate moves the limit with no second write.
library;

import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../models/timeboxed.dart';
import '../utils/timeboxed_limit.dart';
import 'database_provider.dart';

/// The limit status of [outcomeId]'s current Action, live.
///
/// Null when the Outcome is not Timeboxed — which is what keeps every surface
/// that reads this silent for a plain estimate.
final timeboxedLimitStatusProvider = StreamProvider.autoDispose
    .family<TimeboxedLimitStatus?, String>((ref, outcomeId) {
      final db = ref.watch(databaseProvider);
      return _limitStatusStream(db, outcomeId);
    });

/// The limit status of [outcomeId]'s current Action, live.
///
/// Three sources, one value: the current Action, the TimeLogs on it and the
/// Sprints recorded against it. A change in any of them re-reads the others.
///
/// The three are watched together rather than with `asyncExpand`, which pauses
/// its source while the inner stream is open — and the inner stream here never
/// closes, so the Action's own changes (the switch turned off, the estimate
/// raised) would never arrive, and the status would sit on the value it first
/// took.
///
/// Nothing is emitted until all three have spoken once: a status read from a
/// half-read set of rows would be a wrong answer, not a rough one.
Stream<TimeboxedLimitStatus?> _limitStatusStream(
  GtdDatabase db,
  String outcomeId,
) {
  late StreamController<TimeboxedLimitStatus?> controller;
  StreamSubscription<Action?>? actionSub;
  StreamSubscription<List<TimeLog>>? logsSub;
  StreamSubscription<List<Sprint>>? sprintsSub;
  Action? action;
  List<TimeLog> logs = const [];
  List<Sprint> sprints = const [];
  var haveAction = false;
  var haveLogs = false;
  var haveSprints = false;
  var cancelled = false;
  // A synchronous controller cannot fire an event while it is firing one. A
  // write that lands during the delivery would ask for exactly that, so the
  // ask is held and made again on the next turn.
  var delivering = false;
  var pending = false;

  void emit() {
    if (cancelled) return;
    if (!haveAction || !haveLogs || !haveSprints) return;
    if (delivering) {
      pending = true;
      return;
    }
    delivering = true;
    try {
      controller.add(_statusOf(action, logs, sprints));
    } finally {
      delivering = false;
    }
    if (pending) {
      pending = false;
      scheduleMicrotask(emit);
    }
  }

  // A synchronous controller: the status lands on the reader in the same turn
  // the rows change, not a turn later. A reader that asks for the status
  // straight after a write should not be told about the value it just
  // replaced.
  controller = StreamController<TimeboxedLimitStatus?>(
    sync: true,
    onListen: () {
      actionSub = db.actionDao.watchCurrentAction(outcomeId).listen((row) {
        action = row;
        haveAction = true;
        emit();
      }, onError: controller.addError);
      logsSub = _logsOfCurrentAction(db, outcomeId).listen((rows) {
        logs = rows;
        haveLogs = true;
        emit();
      }, onError: controller.addError);
      sprintsSub = _sprintsOfCurrentAction(db, outcomeId).listen((rows) {
        sprints = rows;
        haveSprints = true;
        emit();
      }, onError: controller.addError);
    },
    onCancel: () async {
      cancelled = true;
      await actionSub?.cancel();
      await logsSub?.cancel();
      await sprintsSub?.cancel();
    },
  );
  return controller.stream;
}

/// The TimeLogs on [outcomeId]'s current Action, live.
///
/// Joined to the current Action so the rows follow it: when the Action is
/// superseded, its logs leave the limit and the successor's take their place.
Stream<List<TimeLog>> _logsOfCurrentAction(
  GtdDatabase db,
  String outcomeId,
) {
  final query = db.select(db.timeLogs).join([
    innerJoin(db.actions, db.actions.id.equalsExp(db.timeLogs.actionId)),
  ])
    ..where(
      db.actions.outcomeId.equals(outcomeId) &
          db.actions.role.equals('current'),
    );
  return query
      .watch()
      .map((rows) => [for (final row in rows) row.readTable(db.timeLogs)]);
}

/// The Sprints recorded against [outcomeId]'s current Action, live.
Stream<List<Sprint>> _sprintsOfCurrentAction(
  GtdDatabase db,
  String outcomeId,
) {
  final query = db.select(db.sprints).join([
    innerJoin(db.actions, db.actions.id.equalsExp(db.sprints.actionId)),
  ])
    ..where(
      db.actions.outcomeId.equals(outcomeId) &
          db.actions.role.equals('current'),
    );
  return query
      .watch()
      .map((rows) => [for (final row in rows) row.readTable(db.sprints)]);
}

/// The status of one Action, from its stints and its Sprints.
///
/// Null when the Action is not Timeboxed — which is what keeps every surface
/// that reads this silent for a plain estimate, and what makes the switch
/// turned off leave no status behind.
TimeboxedLimitStatus? _statusOf(
  Action? action,
  List<TimeLog> logs,
  List<Sprint> sprints,
) {
  if (action == null) return null;
  final limit = action.timeEstimate;
  if (!isTimeboxedAction(
    timeboxed: action.timeboxed,
    timeEstimate: limit,
  )) {
    return null;
  }
  return _status(
    limitMinutes: limit!,
    logs: [for (final log in logs) if (log.actionId == action.id) log],
    sprints: [
      for (final sprint in sprints)
        if (sprint.actionId == action.id) sprint,
    ],
  );
}

/// Which Outcomes currently have a Timeboxed Action, live.
///
/// A map of Outcome id to whether that Outcome's current Action is Timeboxed.
/// Used by the Focus list, where a row must show the mark without asking for
/// each Outcome's Action one at a time.
///
/// Not autoDispose, like the other list streams (`nextProvider` and its kin):
/// the Focus screen is replaced as the user moves between surfaces, and a
/// watch torn down and reopened on every move costs more than the one
/// always-open query does.
final currentTimeboxedProvider = StreamProvider<Map<String, bool>>((ref) {
  return ref.watch(databaseProvider).actionDao.watchCurrentTimeboxed();
});

/// The limit status of [outcomeId]'s current Action, read fresh.
///
/// The live provider above is the right thing for a surface that *shows* the
/// limit. The gate is different: it decides whether to interrupt the user
/// *now*, and the limit may have been passed since the last emission — a
/// Sprint can pass the limit while nobody is looking. So the gate reads the
/// rows itself.
///
/// Null when the Outcome is not Timeboxed, or has no current Action.
Future<TimeboxedLimitStatus?> readTimeboxedLimitStatus(
  GtdDatabase db,
  String outcomeId,
) async {
  final action = await db.actionDao.getCurrentAction(outcomeId);
  if (action == null) return null;
  final limit = action.timeEstimate;
  if (!isTimeboxedAction(timeboxed: action.timeboxed, timeEstimate: limit)) {
    return null;
  }
  final logs = await (db.select(
    db.timeLogs,
  )..where((t) => t.actionId.equals(action.id))).get();
  final sprints = await (db.select(
    db.sprints,
  )..where((s) => s.actionId.equals(action.id))).get();
  return _status(limitMinutes: limit!, logs: logs, sprints: sprints);
}

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
