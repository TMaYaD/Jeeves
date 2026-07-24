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

    test(
        'neither off-Plan engagement nor an off-Plan disposition inserts a '
        'focus_session_tasks row (the Plan stays fixed — ADR-0002)',
        () async {
      await _insertTodo(db, id: 'X', title: 'X');
      await _insertTodo(db, id: 'Z', title: 'Z'); // off-Plan

      // Plan contains X only.
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['X'],
        now: DateTime(2026, 5, 1, 9, 0),
      );

      Future<List<String>> planTaskIds() async {
        final rows = await db.customSelect(
          'SELECT task_id FROM focus_session_tasks '
          'WHERE focus_session_id = ?',
          variables: [Variable<String>(sessionId)],
        ).get();
        return rows.map((r) => r.read<String>('task_id')).toList();
      }

      // Off-Plan-engage Z. The Plan must still contain exactly X.
      await _insertOffPlanTimeLog(
        db,
        sessionId: sessionId,
        taskId: 'Z',
        startedAt: DateTime(2026, 5, 1, 10, 0),
      );
      expect(await planTaskIds(), unorderedEquals(<String>['X']),
          reason:
              'Off-Plan engagement must not auto-grow the Plan (ADR-0002).');

      // Dispositioning the off-Plan Outcome (the write path) must likewise
      // leave the Plan fixed — the Disposition lands in
      // focus_session_dispositions, never focus_session_tasks.
      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: sessionId,
        dispositions: {'Z': 'maybe'},
        now: DateTime(2026, 5, 1, 17, 0),
      );
      expect(await planTaskIds(), unorderedEquals(<String>['X']),
          reason:
              'Dispositioning an off-Plan Outcome must not auto-grow the Plan '
              '(ADR-0002).');
    });
  });

  // ---------------------------------------------------------------------------
  // (g) Off-Plan Dispositions have a durable home (issue #418, ADR-0016)
  //
  // An off-Plan engaged Outcome has no focus_session_tasks row (the Plan never
  // auto-grows — ADR-0002), so its Disposition lands in
  // focus_session_dispositions instead. reviewAndCloseSession routes by Plan
  // membership; the query helpers UNION the two homes.
  // ---------------------------------------------------------------------------

  group('Off-Plan Dispositions persist durably (issue #418, ADR-0016)', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    Future<String> openSessionWithOffPlanEngagement({
      required List<String> plan,
      required String offPlanTaskId,
    }) async {
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: plan,
        now: DateTime(2026, 5, 1, 9, 0),
      );
      await _insertOffPlanTimeLog(
        db,
        sessionId: sessionId,
        taskId: offPlanTaskId,
        startedAt: DateTime(2026, 5, 1, 10, 0),
        endedAt: DateTime(2026, 5, 1, 10, 30),
      );
      return sessionId;
    }

    test(
        "off-Plan 'rollover' appears in getLastClosedSessionRolloverTaskIds "
        '(the previously-dropped case)', () async {
      await _insertTodo(db, id: 'X', title: 'X'); // Plan member
      await _insertTodo(db, id: 'Z', title: 'Z'); // off-Plan engaged

      final sessionId = await openSessionWithOffPlanEngagement(
        plan: ['X'],
        offPlanTaskId: 'Z',
      );
      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: sessionId,
        dispositions: {'X': 'leave', 'Z': 'rollover'},
        now: DateTime(2026, 5, 1, 17, 0),
      );

      final ids =
          await db.focusSessionDao.getLastClosedSessionRolloverTaskIds();
      expect(ids, contains('Z'),
          reason:
              'An off-Plan rollover must pre-select for the next session, not '
              'be silently dropped.');
      expect(ids, isNot(contains('X')));
    });

    test(
        "off-Plan 'maybe' flips intent AND stores a durable "
        'focus_session_dispositions row', () async {
      await _insertTodo(db, id: 'Z', title: 'Z', intent: 'next'); // off-Plan

      final sessionId = await openSessionWithOffPlanEngagement(
        plan: [],
        offPlanTaskId: 'Z',
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
      expect(maybeList.map((t) => t.id), contains('Z'));

      // The disposition itself is durably stored off the Plan.
      final dispRows = await db.customSelect(
        'SELECT task_id, disposition FROM focus_session_dispositions '
        'WHERE focus_session_id = ?',
        variables: [Variable<String>(sessionId)],
      ).get();
      expect(dispRows.length, 1);
      expect(dispRows.first.read<String>('task_id'), 'Z');
      expect(dispRows.first.read<String>('disposition'), 'maybe');
    });

    test('off-Plan engaged Outcome gets last_next_action_completion_at stamped',
        () async {
      await _insertTodo(db, id: 'Z', title: 'Z'); // off-Plan engaged

      final sessionId = await openSessionWithOffPlanEngagement(
        plan: [],
        offPlanTaskId: 'Z',
      );
      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: sessionId,
        dispositions: {'Z': 'leave'},
        now: DateTime(2026, 5, 1, 17, 0),
      );

      final after =
          await (db.select(db.todos)..where((t) => t.id.equals('Z')))
              .getSingle();
      expect(after.lastNextActionCompletionAt, isNotNull,
          reason:
              'An off-Plan engaged Outcome was worked on in the session, so it '
              'earns the "worked on" stamp too.');
    });

    test(
        'a mix of Plan + off-Plan dispositions closes cleanly and routes each '
        'to the correct home', () async {
      await _insertTodo(db, id: 'X', title: 'X'); // Plan member → rollover
      await _insertTodo(db, id: 'Z', title: 'Z'); // off-Plan → rollover

      final sessionId = await openSessionWithOffPlanEngagement(
        plan: ['X'],
        offPlanTaskId: 'Z',
      );
      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: sessionId,
        dispositions: {'X': 'rollover', 'Z': 'rollover'},
        now: DateTime(2026, 5, 1, 17, 0),
      );

      // Session closed.
      final closed = await (db.select(db.focusSessions)
            ..where((s) => s.id.equals(sessionId)))
          .getSingle();
      expect(closed.endedAt, isNotNull);

      // Plan member's disposition lives on focus_session_tasks.
      final fstRows = await db.customSelect(
        'SELECT task_id, disposition FROM focus_session_tasks '
        'WHERE focus_session_id = ?',
        variables: [Variable<String>(sessionId)],
      ).get();
      expect(fstRows.map((r) => r.read<String>('task_id')),
          unorderedEquals(<String>['X']));
      expect(fstRows.first.read<String>('disposition'), 'rollover');

      // Off-Plan member's disposition lives on focus_session_dispositions.
      final dispRows = await db.customSelect(
        'SELECT task_id, disposition FROM focus_session_dispositions '
        'WHERE focus_session_id = ?',
        variables: [Variable<String>(sessionId)],
      ).get();
      expect(dispRows.map((r) => r.read<String>('task_id')),
          unorderedEquals(<String>['Z']));

      // Both roll over into the next session's pre-selection.
      final ids =
          await db.focusSessionDao.getLastClosedSessionRolloverTaskIds();
      expect(ids, unorderedEquals(<String>['X', 'Z']));
    });
  });
}
