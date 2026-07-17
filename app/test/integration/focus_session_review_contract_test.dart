/// Regression-proof coverage for the FocusSession Review-phase disposition
/// contract. This test file is the canonical anchor for the invariants the
/// Engagement context (CONTEXT.md) and ADR-0002 / ADR-0005 promise but that
/// risk silent breakage when the Review path is refactored:
///
///   (a) Review surface = Plan ∪ off-Plan engaged Outcomes (CONTEXT.md line
///       ~259). The Review phase surfaces every Outcome that was either on
///       the Plan **or** engaged with during the session; neither off-Plan
///       work nor planned-but-untouched Outcomes slip past disposition.
///
///   (b) Per-(FocusSession, Outcome) Disposition values: 'rollover' /
///       'leave' / 'maybe' (CONTEXT.md line ~245-251). The semantics:
///         - rollover → pre-select for the next FocusSession's Planning.
///         - leave    → return to normal List membership; no mutation.
///         - maybe    → set Outcome.intent='maybe' (Someday/Maybe).
///
///   (c) Completed Outcomes need no Disposition (CONTEXT.md line ~251).
///
///   (d) Plan stays fixed during Execution (ADR-0002). Off-Plan engagement
///       attributes to the session but does **not** modify the Plan.
///
/// These tests poke the DAO directly because the contract is enforced at
/// the storage boundary — fst rows, todos.intent, and time_logs.
/// focus_session_id are the durable surfaces; the providers are UI plumbing
/// on top.
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:powersync/powersync.dart' show uuid;

import 'package:jeeves/database/gtd_database.dart';
import '../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

const _userId = 'test-user';

Future<void> _insertTodo(
  GtdDatabase db, {
  required String id,
  required String title,
  String intent = 'next',
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
    id: Value(id),
    title: Value(title),
    clarified: const Value(true),
    intent: Value(intent),
    userId: const Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
}

/// Inserts a TimeLog row directly against [sessionId] for [taskId], emulating
/// off-Plan engagement as the conceptual model (CONTEXT.md + ADR-0005)
/// permits.  The production path is the task detail screen's "Start focus"
/// affordance (issue #180); we exercise the storage surface directly so the
/// Review-side contract stays covered independently of the UI.
Future<void> _insertOffPlanTimeLog(
  GtdDatabase db, {
  required String sessionId,
  required String taskId,
  required DateTime startedAt,
  DateTime? endedAt,
}) async {
  await db.into(db.timeLogs).insert(TimeLogsCompanion(
    id: Value(uuid.v4()),
    userId: const Value(_userId),
    taskId: Value(taskId),
    startedAt: Value(startedAt.toUtc().toIso8601String()),
    endedAt: Value(endedAt?.toUtc().toIso8601String()),
    focusSessionId: Value(sessionId),
  ));
}

void main() {
  setUpAll(configureSqliteForTests);

  // ---------------------------------------------------------------------------
  // (a) Review surface union
  //
  // CONTEXT.md (Engagement, Relationships): "The Review phase surfaces every
  // Outcome that was either on the Plan or engaged with during the session
  // (the union), so neither off-Plan work nor planned-but-untouched
  // Outcomes slip past disposition."
  // ---------------------------------------------------------------------------

  group('Review surface — Plan ∪ off-Plan engaged (CONTEXT.md ~259)', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('contains Plan members AND off-Plan engaged Outcomes, no duplicates',
        () async {
      await _insertTodo(db, id: 'X', title: 'Outcome X');
      await _insertTodo(db, id: 'Y', title: 'Outcome Y');
      await _insertTodo(db, id: 'Z', title: 'Outcome Z');

      // Plan: X and Y.
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['X', 'Y'],
        now: DateTime(2026, 5, 1, 9, 0),
      );

      // Engage X (a Plan member) and off-Plan-engage Z.
      await db.focusSessionDao.setCurrentTask(
        sessionId: sessionId,
        taskId: 'X',
        now: DateTime(2026, 5, 1, 9, 30),
      );
      await _insertOffPlanTimeLog(
        db,
        sessionId: sessionId,
        taskId: 'Z',
        startedAt: DateTime(2026, 5, 1, 10, 0),
      );

      final surface = await db.focusSessionDao.getReviewSurface(sessionId);

      expect(
        surface.map((t) => t.id),
        unorderedEquals(<String>['X', 'Y', 'Z']),
        reason: 'Review surface must be Plan ∪ off-Plan engaged.',
      );

      // No duplicates even though X is both on the Plan and engaged.
      expect(surface.length, equals(3));
    });

    test('returns Plan members in position order followed by off-Plan engaged',
        () async {
      await _insertTodo(db, id: 'X', title: 'X');
      await _insertTodo(db, id: 'Y', title: 'Y');
      await _insertTodo(db, id: 'Z', title: 'Z');

      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['X', 'Y'],
        now: DateTime(2026, 5, 1, 9, 0),
      );
      await _insertOffPlanTimeLog(
        db,
        sessionId: sessionId,
        taskId: 'Z',
        startedAt: DateTime(2026, 5, 1, 10, 0),
      );

      final surface = await db.focusSessionDao.getReviewSurface(sessionId);

      // Plan members keep their position order; engaged-but-off-Plan trails.
      expect(surface.map((t) => t.id), orderedEquals(<String>['X', 'Y', 'Z']));
    });

    test(
        'omits off-Plan engagement that targeted a different session '
        '(no leakage across sessions)',
        () async {
      await _insertTodo(db, id: 'X', title: 'X');
      await _insertTodo(db, id: 'Q', title: 'Q'); // engaged in a prior session

      // Prior session — close it after a TimeLog against Q.
      final priorId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: [],
        now: DateTime(2026, 4, 30, 9, 0),
      );
      await _insertOffPlanTimeLog(
        db,
        sessionId: priorId,
        taskId: 'Q',
        startedAt: DateTime(2026, 4, 30, 10, 0),
        endedAt: DateTime(2026, 4, 30, 10, 30),
      );
      await db.focusSessionDao.closeSession(
        sessionId: priorId,
        now: DateTime(2026, 4, 30, 17, 0),
      );

      // Today's session contains X only; Q must not bleed through.
      final todayId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['X'],
        now: DateTime(2026, 5, 1, 9, 0),
      );

      final surface = await db.focusSessionDao.getReviewSurface(todayId);
      expect(surface.map((t) => t.id), unorderedEquals(<String>['X']));
    });
  });

  // ---------------------------------------------------------------------------
  // (b) rollover → next-session pre-selection
  //
  // CONTEXT.md (Engagement, Disposition):
  //   rollover — pre-select this Outcome for the next FocusSession's
  //   Planning (user can deselect there).
  //
  // The planning provider pre-populates pendingSelectedTaskIds via
  // FocusSessionDao.getLastClosedSessionRolloverTaskIds (provider line ~390).
  // ---------------------------------------------------------------------------

  group("'rollover' disposition pre-selects for the next FocusSession's "
      'Planning', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('appears in getLastClosedSessionRolloverTaskIds', () async {
      await _insertTodo(db, id: 'X', title: 'X');

      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['X'],
        now: DateTime(2026, 5, 1, 9, 0),
      );
      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: sessionId,
        dispositions: {'X': 'rollover'},
        now: DateTime(2026, 5, 1, 17, 0),
      );

      final ids =
          await db.focusSessionDao.getLastClosedSessionRolloverTaskIds();
      expect(ids, unorderedEquals(<String>['X']));
    });
  });

  // ---------------------------------------------------------------------------
  // (c) 'leave' → no mutation, not pre-selected
  //
  // CONTEXT.md (Engagement, Disposition):
  //   leave — return to its normal List membership; no special handling.
  // ---------------------------------------------------------------------------

  group("'leave' disposition leaves the Outcome untouched", () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test("does not change todos.intent and does not pre-select for "
        'the next session', () async {
      await _insertTodo(db, id: 'Y', title: 'Y', intent: 'next');

      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['Y'],
        now: DateTime(2026, 5, 1, 9, 0),
      );
      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: sessionId,
        dispositions: {'Y': 'leave'},
        now: DateTime(2026, 5, 1, 17, 0),
      );

      final after =
          await (db.select(db.todos)..where((t) => t.id.equals('Y')))
              .getSingle();
      expect(after.intent, equals('next'),
          reason: 'leave disposition must not mutate intent.');

      final rolloverIds =
          await db.focusSessionDao.getLastClosedSessionRolloverTaskIds();
      expect(rolloverIds, isNot(contains('Y')),
          reason:
              'leave-dispositioned Outcomes must not be pre-selected for the next session.');
    });
  });

  // ---------------------------------------------------------------------------
  // (d) 'maybe' → Intent flips, Outcome appears in Someday/Maybe
  //
  // CONTEXT.md (Engagement, Disposition):
  //   maybe — set Intent to 'maybe', moving the Outcome to Someday/Maybe.
  // The Someday/Maybe filter is TodoDao.watchMaybe.
  // ---------------------------------------------------------------------------

  group("'maybe' disposition flips intent and surfaces in Someday/Maybe", () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('Outcome.intent becomes "maybe" and appears in watchMaybe',
        () async {
      await _insertTodo(db, id: 'Z', title: 'Z', intent: 'next');

      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['Z'],
        now: DateTime(2026, 5, 1, 9, 0),
      );
      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: sessionId,
        dispositions: {'Z': 'maybe'},
        now: DateTime(2026, 5, 1, 17, 0),
      );

      final after =
          await (db.select(db.todos)..where((t) => t.id.equals('Z')))
              .getSingle();
      expect(after.intent, equals('maybe'));

      final maybeList = await db.todoDao.watchMaybe().first;
      expect(maybeList.map((t) => t.id), contains('Z'),
          reason:
              'maybe-dispositioned Outcome must appear in the Someday/Maybe List.');
    });
  });

  // ---------------------------------------------------------------------------
  // (e) Completed Outcomes need no Disposition
  //
  // CONTEXT.md (Engagement, Disposition, last paragraph):
  //   "Completed Outcomes need no Disposition."
  //
  // Operationally: closing the session with an empty / partial dispositions
  // map (omitting the completed Outcomes) must succeed.  The row in
  // focus_session_tasks for a completed task is left with NULL disposition,
  // per the column docstring in tables.dart.
  // ---------------------------------------------------------------------------

  group('Completed Outcomes need no Disposition (CONTEXT.md ~251)', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test(
        'closing the session does not require a disposition for tasks that '
        'completed mid-session', () async {
      await _insertTodo(db, id: 'X', title: 'X');
      await _insertTodo(db, id: 'Y', title: 'Y');

      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['X', 'Y'],
        now: DateTime(2026, 5, 1, 9, 0),
      );

      // Complete X mid-session.
      await db.todoDao.markDone('X', now: DateTime(2026, 5, 1, 10, 0));

      // Caller omits X from the dispositions map (it is done) and closes —
      // this must succeed.
      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: sessionId,
        dispositions: {'Y': 'leave'},
        now: DateTime(2026, 5, 1, 17, 0),
      );

      // Session must be closed.
      final closed =
          await (db.select(db.focusSessions)..where((s) => s.id.equals(sessionId)))
              .getSingle();
      expect(closed.endedAt, isNotNull);

      // X's focus_session_tasks row is left with NULL disposition (per
      // tables.dart docstring).
      final rows = await db.customSelect(
        'SELECT task_id, disposition FROM focus_session_tasks '
        'WHERE focus_session_id = ?',
        variables: [Variable<String>(sessionId)],
      ).get();
      final fstX =
          rows.firstWhere((r) => r.read<String>('task_id') == 'X');
      expect(fstX.read<String?>('disposition'), isNull,
          reason:
              'Completed Outcome must not require a Disposition — its fst row '
              'remains NULL without blocking session close.');
    });
  });

  // ---------------------------------------------------------------------------
  // (f) Plan stays fixed during Execution (ADR-0002)
  //
  // ADR-0002: "Plan stays fixed at Planning. Off-Plan engagement is allowed
  // (per ADR-0005) and attributes to the session, but does not modify the
  // Plan."
  //
  // Concretely: an off-Plan TimeLog against the session must not implicitly
  // mint a row in focus_session_tasks for the off-Plan Outcome.
  // ---------------------------------------------------------------------------

  group('Plan stays fixed during Execution (ADR-0002)', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    test('off-Plan engagement does NOT insert a focus_session_tasks row',
        () async {
      await _insertTodo(db, id: 'X', title: 'X');
      await _insertTodo(db, id: 'Z', title: 'Z'); // off-Plan

      // Plan contains X only.
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['X'],
        now: DateTime(2026, 5, 1, 9, 0),
      );

      // Off-Plan-engage Z.
      await _insertOffPlanTimeLog(
        db,
        sessionId: sessionId,
        taskId: 'Z',
        startedAt: DateTime(2026, 5, 1, 10, 0),
      );

      // The Plan must still contain exactly X.
      final fstRows = await db.customSelect(
        'SELECT task_id FROM focus_session_tasks '
        'WHERE focus_session_id = ?',
        variables: [Variable<String>(sessionId)],
      ).get();
      expect(fstRows.map((r) => r.read<String>('task_id')),
          unorderedEquals(<String>['X']),
          reason:
              'Off-Plan engagement must not auto-grow the Plan (ADR-0002).');
    });

    test(
        'off-Plan engagement still attributes to the session (TimeLog '
        'carries focus_session_id) — ADR-0005', () async {
      await _insertTodo(db, id: 'Z', title: 'Z');

      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: [],
        now: DateTime(2026, 5, 1, 9, 0),
      );
      await _insertOffPlanTimeLog(
        db,
        sessionId: sessionId,
        taskId: 'Z',
        startedAt: DateTime(2026, 5, 1, 10, 0),
      );

      final logs = await (db.select(db.timeLogs)
            ..where((l) => l.taskId.equals('Z')))
          .get();
      expect(logs.length, 1);
      expect(logs.first.focusSessionId, equals(sessionId),
          reason:
              'Off-Plan engagement attributes to the open FocusSession (ADR-0005).');
    });
  });
}
