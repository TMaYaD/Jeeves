/// Action completion as a first-class transition (ADR-0001 story 4, issue #474).
///
/// Completion is the one Action mutation that is **not** a clarifying act: the
/// current Action flips to `role='done'` and the Outcome enters the no-current-
/// Action state (ADR-0004) *without* `last_clarified_at` moving, so the Outcome
/// immediately owes a re-clarification. These tests pin that non-stamp, the
/// mandatory cursor clear (without which the startup sweep resurrects the
/// completed Action), and the Outcome-completion cascade on both write paths
/// that set `todos.done_at`.
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart' show Intent, RoutingKind;
import '../test_helpers.dart';

const _userId = 'test-user';
final _t0 = DateTime.parse('2026-07-01T09:00:00.000Z');
final _t1 = DateTime.parse('2026-07-01T10:00:00.000Z');
final _t2 = DateTime.parse('2026-07-01T11:00:00.000Z');
final _t3 = DateTime.parse('2026-07-01T12:00:00.000Z');

/// Seeds a clarified Outcome with a real `current` Action **and** a legacy
/// cursor value, as a store written by a pre-retirement client would look. The
/// cursor is seeded purely so the "nothing writes it" assertions below are
/// observable — production never sets it any more (ADR-0022).
Future<void> _seedClarifiedOutcome(
  GtdDatabase db, {
  String id = 'o1',
  String actionText = 'call the plumber',
  DateTime? lastClarifiedAt,
}) async {
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Outcome $id'),
        userId: const Value(_userId),
        clarified: const Value(true),
        intent: const Value('next'),
        createdAt: Value(_t0),
        nextActionText: Value(actionText),
        lastClarifiedAt: Value(lastClarifiedAt ?? _t1),
      ));
  await db.into(db.actions).insert(ActionsCompanion(
        id: Value('action-$id'),
        outcomeId: Value(id),
        userId: const Value(_userId),
        actionText: Value(actionText),
        role: const Value('current'),
        createdAt: Value(_t1),
        updatedAt: Value(_t1),
      ));
}

Future<List<Map<String, Object?>>> _actions(
  GtdDatabase db,
  String outcomeId,
) async {
  final rows = await db
      .customSelect(
        'SELECT * FROM actions WHERE outcome_id = ? ORDER BY created_at, id',
        variables: [Variable<String>(outcomeId)],
      )
      .get();
  return rows.map((r) => r.data).toList();
}

Future<Map<String, Object?>?> _current(GtdDatabase db, String outcomeId) async {
  final rows = await db
      .customSelect(
        "SELECT * FROM actions WHERE outcome_id = ? AND role = 'current'",
        variables: [Variable<String>(outcomeId)],
      )
      .get();
  return rows.isEmpty ? null : rows.single.data;
}

Future<Todo> _outcome(GtdDatabase db, String id) =>
    (db.select(db.todos)..where((t) => t.id.equals(id))).getSingle();

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  setUp(() => db = GtdDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  group('ActionDao.completeCurrentAction', () {
    test(
        'terminates the current Action, writes nothing to the Outcome row, '
        'leaves it undone and unstamped, and lands it in needs-review',
        () async {
      await _seedClarifiedOutcome(db, lastClarifiedAt: _t1);
      final before = await _outcome(db, 'o1');

      await db.actionDao.completeCurrentAction('o1', now: _t2);

      final rows = await _actions(db, 'o1');
      expect(rows, hasLength(1), reason: 'completion terminates, never mints');
      expect(rows.single['role'], 'done');
      expect(rows.single['done_at'], _t2.toIso8601String());
      expect(rows.single['updated_at'], _t2.toIso8601String());

      final outcome = await _outcome(db, 'o1');
      expect(outcome.doneAt, isNull,
          reason: 'finishing one Action never completes the Outcome');
      expect(outcome.lastClarifiedAt, _t1,
          reason: 'completion is an engagement signal, not a clarifying act');
      expect(outcome.nextActionText, 'call the plumber',
          reason: 'the retired cursor is neither read nor written (ADR-0022)');
      // Deliberate consequence of retiring the cursor: completion is now a
      // pure `actions` write, so the Outcome row's `updated_at` no longer moves
      // and stops being a "something about this Outcome changed" signal. The
      // view-notify (see action_view_notify_test.dart) is what keeps watchers
      // correct; nothing may reintroduce a `todos` write to restore the churn.
      expect(outcome.updatedAt, before.updatedAt,
          reason: 'completion writes nothing to `todos`');

      expect(await db.actionDao.getCurrentAction('o1'), isNull);

      final review = await db.todoDao.getNeedsReview();
      expect(review.map((t) => t.id), ['o1'],
          reason: 'the completed Outcome immediately owes a re-clarification');
    });

    test('is a no-op on an Actionless Outcome — nothing written, nothing stamped',
        () async {
      await db.into(db.todos).insert(TodosCompanion(
            id: const Value('bare'),
            title: const Value('Bare'),
            userId: const Value(_userId),
            createdAt: Value(_t0),
            lastClarifiedAt: Value(_t1),
          ));

      await db.actionDao.completeCurrentAction('bare', now: _t2);

      expect(await _actions(db, 'bare'), isEmpty);
      final outcome = await _outcome(db, 'bare');
      expect(outcome.lastClarifiedAt, _t1);
      expect(outcome.updatedAt, isNull);
    });

    test('is idempotent: a second call produces no duplicate terminal row and '
        'never resurrects the current role', () async {
      await _seedClarifiedOutcome(db, lastClarifiedAt: _t1);

      await db.actionDao.completeCurrentAction('o1', now: _t2);
      await db.actionDao.completeCurrentAction('o1', now: _t3);

      final rows = await _actions(db, 'o1');
      expect(rows, hasLength(1));
      expect(rows.single['role'], 'done');
      expect(rows.single['done_at'], _t2.toIso8601String(),
          reason: 'the replay must not move the completion timestamp');
      expect(await _outcome(db, 'o1').then((o) => o.lastClarifiedAt), _t1);
    });

    test('converges an accidental multi-current set first, then completes the '
        'winner', () async {
      await _seedClarifiedOutcome(db, lastClarifiedAt: _t0);
      // A second `current` row synced in from another device; the winner is the
      // one with the greatest COALESCE(updated_at, created_at).
      await db.into(db.actions).insert(ActionsCompanion(
            id: const Value('zz-newer'),
            outcomeId: const Value('o1'),
            userId: const Value(_userId),
            actionText: const Value('the newer one'),
            role: const Value('current'),
            createdAt: Value(_t1),
            updatedAt: Value(_t2),
          ));

      await db.actionDao.completeCurrentAction('o1', now: _t3);

      final rows = {
        for (final r in await _actions(db, 'o1')) r['id'] as String: r,
      };
      expect(rows['zz-newer']!['role'], 'done',
          reason: 'the winner is the Action the user was engaged with');
      expect(rows['zz-newer']!['done_at'], _t3.toIso8601String());
      expect(rows['action-o1']!['role'], 'superseded',
          reason: 'the loser is repaired, not completed');
      expect(await _current(db, 'o1'), isNull);
      expect(await _outcome(db, 'o1').then((o) => o.lastClarifiedAt), _t0,
          reason: 'neither the convergence nor the completion stamps');
    });
  });

  group('Outcome-completion cascade', () {
    test('markDone terminates the current Action and keeps its own stamp',
        () async {
      await _seedClarifiedOutcome(db, lastClarifiedAt: _t1);
      // A planned row is history the cascade must not touch (story 5 mints it).
      await db.into(db.actions).insert(ActionsCompanion(
            id: const Value('planned-1'),
            outcomeId: const Value('o1'),
            userId: const Value(_userId),
            actionText: const Value('later'),
            role: const Value('planned'),
            createdAt: Value(_t1),
          ));

      final affected = await db.todoDao.markDone('o1', now: _t2);
      expect(affected, 1, reason: 'return contract preserved');

      final outcome = await _outcome(db, 'o1');
      expect(outcome.doneAt, isNotNull);
      expect(outcome.lastClarifiedAt, _t2,
          reason: 'completing the Outcome is a clarifying act — it stamps');
      expect(outcome.nextActionText, 'call the plumber',
          reason: 'the completion cascade does not touch the retired cursor');

      final rows = {
        for (final r in await _actions(db, 'o1')) r['id'] as String: r,
      };
      expect(rows['action-o1']!['role'], 'done');
      expect(rows['action-o1']!['done_at'], _t2.toIso8601String());
      expect(rows['planned-1']!['role'], 'planned',
          reason: 'planned rows survive as history');
    });

    test('markDone on an Actionless Outcome cascades cleanly', () async {
      await db.into(db.todos).insert(TodosCompanion(
            id: const Value('bare'),
            title: const Value('Bare'),
            userId: const Value(_userId),
            createdAt: Value(_t0),
          ));

      expect(await db.todoDao.markDone('bare', now: _t2), 1);
      expect(await _actions(db, 'bare'), isEmpty);
      expect(await _outcome(db, 'bare').then((o) => o.doneAt), isNotNull);
    });

    test('markDone on a missing row still reports 0 affected', () async {
      expect(await db.todoDao.markDone('ghost', now: _t2), 0);
    });

    test('applyRouting(to: done) terminates the current Action too', () async {
      await _seedClarifiedOutcome(db, lastClarifiedAt: _t1);

      await db.todoDao.applyRouting('o1', to: RoutingKind.done, now: _t2);

      final outcome = await _outcome(db, 'o1');
      expect(outcome.doneAt, isNotNull);
      expect(outcome.lastClarifiedAt, _t2);
      expect(outcome.nextActionText, 'call the plumber',
          reason: 'the completion cascade does not touch the retired cursor');
      final rows = await _actions(db, 'o1');
      expect(rows.single['role'], 'done');
      expect(rows.single['done_at'], _t2.toIso8601String());
    });

    test('applyRouting(to: maybe) leaves the Action alone', () async {
      await _seedClarifiedOutcome(db, lastClarifiedAt: _t1);

      await db.todoDao.applyRouting('o1', to: RoutingKind.maybe, now: _t2);

      expect((await _current(db, 'o1'))!['id'], 'action-o1');
      expect(await _outcome(db, 'o1').then((o) => o.nextActionText),
          'call the plumber');
    });

    test('trashing leaves Action rows untouched — rows persist like the '
        'Outcome row does', () async {
      await _seedClarifiedOutcome(db, id: 'ta', lastClarifiedAt: _t1);
      await _seedClarifiedOutcome(db, id: 'tb', lastClarifiedAt: _t1);

      await db.todoDao.setIntent('ta', Intent.trash, now: _t2);
      await db.todoDao.applyRouting('tb', to: RoutingKind.trash, now: _t2);

      for (final id in ['ta', 'tb']) {
        final cur = await _current(db, id);
        expect(cur, isNotNull, reason: '$id keeps its current Action');
        expect(cur!['role'], 'current');
        expect(cur['updated_at'], _t1.toIso8601String(),
            reason: '$id: the row is not even touched');
      }
    });
  });

  group('Terminal-transition TimeLog hook (issue #476)', () {
    // Opens a log against the seeded current Action `action-$outcomeId`.
    Future<void> openLogAgainstCurrent(
      String outcomeId, {
      String logId = 'log-1',
      String? focusSessionId = 'session-1',
    }) async {
      await db.into(db.timeLogs).insert(TimeLogsCompanion(
            id: Value(logId),
            userId: const Value(_userId),
            taskId: Value(outcomeId),
            actionId: Value('action-$outcomeId'),
            startedAt: Value(_t1.toIso8601String()),
            focusSessionId: Value(focusSessionId),
          ));
    }

    Future<List<TimeLog>> logs(GtdDatabase db) =>
        (db.select(db.timeLogs)
              ..orderBy([(t) => OrderingTerm(expression: t.startedAt)]))
            .get();

    test('completeCurrentAction closes the open log on that Action at ts',
        () async {
      await _seedClarifiedOutcome(db, lastClarifiedAt: _t1);
      await openLogAgainstCurrent('o1');

      await db.actionDao.completeCurrentAction('o1', now: _t2);

      final rows = await logs(db);
      expect(rows, hasLength(1), reason: 'no reopen on Done');
      expect(rows.single.actionId, 'action-o1');
      expect(rows.single.endedAt, _t2.toIso8601String(),
          reason: 'engagement ended at Done');
    });

    test('supersede-with-replacement closes the old log and reopens against '
        'the successor, losing no time', () async {
      await _seedClarifiedOutcome(db, lastClarifiedAt: _t1);
      await openLogAgainstCurrent('o1');

      await db.actionDao
          .supersedeCurrentAction('o1', newActionText: 'the next step', now: _t2);

      final successor = await db.actionDao.getCurrentAction('o1');
      expect(successor, isNotNull);
      expect(successor!.actionText, 'the next step');

      final rows = await logs(db);
      expect(rows, hasLength(2), reason: 'close-and-reopen');
      final closed = rows.firstWhere((r) => r.id == 'log-1');
      final reopened = rows.firstWhere((r) => r.id != 'log-1');
      expect(closed.endedAt, _t2.toIso8601String());
      // Continuity: closed.ended_at == reopened.started_at == ts, zero lost.
      expect(reopened.startedAt, _t2.toIso8601String());
      expect(reopened.endedAt, isNull);
      expect(reopened.actionId, successor.id);
      // The reopened row copies task_id, user_id AND focus_session_id.
      expect(reopened.taskId, 'o1');
      expect(reopened.userId, closed.userId);
      expect(reopened.focusSessionId, closed.focusSessionId);
    });

    test('supersedeAndPromote closes the old log and reopens against the '
        'promoted planned Action, not the retired one', () async {
      await _seedClarifiedOutcome(db, lastClarifiedAt: _t1);
      await openLogAgainstCurrent('o1');
      // A planned successor for the "Replace current action" gesture.
      await db.actionDao.addPlannedAction('o1', 'the planned step', now: _t1);
      final planned = (await db.actionDao.getPlannedActions('o1')).single;

      await db.actionDao.supersedeAndPromote(planned.id, now: _t2);

      // The promoted row is now the Outcome's current Action.
      final successor = await db.actionDao.getCurrentAction('o1');
      expect(successor, isNotNull);
      expect(successor!.id, planned.id);

      final rows = await logs(db);
      expect(rows, hasLength(2), reason: 'close-and-reopen');
      final closed = rows.firstWhere((r) => r.id == 'log-1');
      final reopened = rows.firstWhere((r) => r.id != 'log-1');
      expect(closed.endedAt, _t2.toIso8601String());
      expect(closed.actionId, 'action-o1',
          reason: 'the closed log stays on the retired Action');
      // Continuity: closed.ended_at == reopened.started_at == ts, zero lost.
      expect(reopened.startedAt, _t2.toIso8601String());
      expect(reopened.endedAt, isNull);
      expect(reopened.actionId, planned.id,
          reason: 'continuation attaches to the successor, not the retired '
              'Action');
      // The reopened row copies task_id, user_id AND focus_session_id.
      expect(reopened.taskId, 'o1');
      expect(reopened.userId, closed.userId);
      expect(reopened.focusSessionId, closed.focusSessionId);
    });

    test('supersedeAndPromote with no open log promotes without a reopen',
        () async {
      await _seedClarifiedOutcome(db, lastClarifiedAt: _t1);
      // No open log this time.
      await db.actionDao.addPlannedAction('o1', 'the planned step', now: _t1);
      final planned = (await db.actionDao.getPlannedActions('o1')).single;

      await db.actionDao.supersedeAndPromote(planned.id, now: _t2);

      final rows = await logs(db);
      expect(rows, isEmpty, reason: 'nothing to close, nothing to reopen');
      final successor = await db.actionDao.getCurrentAction('o1');
      expect(successor!.id, planned.id);
    });

    test('clear (supersede without replacement) closes the log, no reopen',
        () async {
      await _seedClarifiedOutcome(db, lastClarifiedAt: _t1);
      await openLogAgainstCurrent('o1');

      await db.actionDao.clearCurrentAction('o1', now: _t2);

      final rows = await logs(db);
      expect(rows, hasLength(1));
      expect(rows.single.endedAt, _t2.toIso8601String());
    });

    test('in-place edit leaves the open log untouched (same Action id)',
        () async {
      await _seedClarifiedOutcome(db, lastClarifiedAt: _t1);
      await openLogAgainstCurrent('o1');

      await db.actionDao.setCurrentAction('o1', 'refined wording', now: _t2);

      final rows = await logs(db);
      expect(rows, hasLength(1), reason: 'a text edit is not a transition');
      expect(rows.single.actionId, 'action-o1');
      expect(rows.single.endedAt, isNull, reason: 'the stint keeps running');
    });

    test('supersede leaves a log open against a *different* Action untouched',
        () async {
      await _seedClarifiedOutcome(db, id: 'o1', lastClarifiedAt: _t1);
      await _seedClarifiedOutcome(db, id: 'o2', lastClarifiedAt: _t1);
      // The user is engaged on o2's Action, not o1's.
      await openLogAgainstCurrent('o2', logId: 'log-o2');

      await db.actionDao.clearCurrentAction('o1', now: _t2);

      final rows = await logs(db);
      expect(rows, hasLength(1));
      expect(rows.single.id, 'log-o2');
      expect(rows.single.endedAt, isNull,
          reason: 'only the terminated Action\'s own log is closed');
    });
  });
}
