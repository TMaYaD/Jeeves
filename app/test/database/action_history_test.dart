/// Action history reads (ADR-0001 story 8, issue #478).
///
/// The Outcome's history is the time-ordered chain of its terminated Actions
/// (`done` + `superseded`, CONTEXT.md § Action). These tests drive
/// `ActionDao.watchTerminatedActions` / `getTerminatedActions` against an
/// in-memory SQLite database where `actions` is a real table, pinning the three
/// things a future refactor could silently break: the role filter (planned and
/// current rows must never leak into history), the newest-first ordering by
/// `COALESCE(done_at, updated_at, created_at)` with an `id ASC` tie-break, and
/// the per-Action logged minutes joined in a single query.
///
/// Timestamps here use whole-second gaps: `store_date_time_values_as_text` makes
/// the ordering expression a lexicographic string sort, so sub-millisecond
/// deltas would pin nothing.
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/daos/action_dao.dart' show TerminatedAction;
import 'package:jeeves/database/gtd_database.dart';
import '../test_helpers.dart';

const _userId = 'test-user';
final _t0 = DateTime.parse('2026-07-01T09:00:00.000Z');

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

Future<void> _seedOutcome(GtdDatabase db, {String id = 'o1'}) async {
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Outcome $id'),
        userId: const Value(_userId),
        createdAt: Value(_t0),
      ));
}

/// Insert an `actions` row verbatim — history ordering is a property of the
/// stored timestamps, so the tests set them directly rather than reaching them
/// through the write primitives.
Future<void> _seedAction(
  GtdDatabase db, {
  required String id,
  required String role,
  required String text,
  String outcomeId = 'o1',
  DateTime? createdAt,
  DateTime? updatedAt,
  DateTime? doneAt,
  int? position,
}) async {
  await db.into(db.actions).insert(ActionsCompanion(
        id: Value(id),
        outcomeId: Value(outcomeId),
        userId: const Value(_userId),
        actionText: Value(text),
        role: Value(role),
        position: Value(position),
        createdAt: Value(createdAt ?? _t0),
        updatedAt: Value(updatedAt),
        doneAt: Value(doneAt),
      ));
}

Future<void> _seedClosedLog(
  GtdDatabase db, {
  required String id,
  required String? actionId,
  required DateTime startedAt,
  required Duration duration,
  String taskId = 'o1',
}) async {
  await db.into(db.timeLogs).insert(TimeLogsCompanion(
        id: Value(id),
        userId: const Value(_userId),
        taskId: Value(taskId),
        actionId: Value(actionId),
        startedAt: Value(startedAt.toUtc().toIso8601String()),
        endedAt: Value(startedAt.add(duration).toUtc().toIso8601String()),
      ));
}

void main() {
  setUpAll(configureSqliteForTests);

  group('ActionDao — terminated-Action history reads (issue #478)', () {
    late GtdDatabase db;

    setUp(() async {
      db = _openInMemory();
      await _seedOutcome(db);
    });
    tearDown(() async => db.close());

    test('excludes planned and current rows', () async {
      await _seedAction(db, id: 'a-planned', role: 'planned', text: 'later',
          position: 0);
      await _seedAction(db, id: 'a-current', role: 'current', text: 'now',
          updatedAt: _t0.add(const Duration(seconds: 10)));
      await _seedAction(db, id: 'a-done', role: 'done', text: 'finished',
          doneAt: _t0.add(const Duration(seconds: 20)));
      await _seedAction(db, id: 'a-super', role: 'superseded', text: 'dropped',
          updatedAt: _t0.add(const Duration(seconds: 30)));

      final history = await db.actionDao.getTerminatedActions('o1');

      expect(history.map((h) => h.action.id), ['a-super', 'a-done'],
          reason: 'only done + superseded rows are history');
    });

    test('scopes to the Outcome', () async {
      await _seedOutcome(db, id: 'o2');
      await _seedAction(db, id: 'mine', role: 'done', text: 'mine',
          doneAt: _t0.add(const Duration(seconds: 10)));
      await _seedAction(db, id: 'theirs', role: 'done', text: 'theirs',
          outcomeId: 'o2', doneAt: _t0.add(const Duration(seconds: 20)));

      final history = await db.actionDao.getTerminatedActions('o1');

      expect(history.map((h) => h.action.id), ['mine']);
    });

    test('ordering is newest-first by COALESCE(done_at, updated_at, created_at)',
        () async {
      // The crux: this `done` row's `updated_at` is the NEWEST timestamp in the
      // fixture, but its `done_at` is the OLDEST — so an ordering that read
      // `updated_at` first would put it on top. COALESCE(done_at, …) puts it
      // last. A row with neither falls back to `created_at`.
      await _seedAction(db, id: 'a-done-old', role: 'done', text: 'done early',
          createdAt: _t0,
          doneAt: _t0.add(const Duration(seconds: 10)),
          updatedAt: _t0.add(const Duration(seconds: 90)));
      await _seedAction(db, id: 'b-super-mid', role: 'superseded',
          text: 'abandoned',
          createdAt: _t0,
          updatedAt: _t0.add(const Duration(seconds: 40)));
      await _seedAction(db, id: 'c-done-new', role: 'done', text: 'done late',
          createdAt: _t0,
          doneAt: _t0.add(const Duration(seconds: 70)));
      await _seedAction(db, id: 'd-super-bare', role: 'superseded',
          text: 'no updated_at',
          createdAt: _t0.add(const Duration(seconds: 5)));

      final history = await db.actionDao.getTerminatedActions('o1');

      expect(
        history.map((h) => h.action.id),
        ['c-done-new', 'b-super-mid', 'a-done-old', 'd-super-bare'],
      );
    });

    test('ties break on id ASC so every device renders the same order',
        () async {
      final shared = _t0.add(const Duration(seconds: 30));
      await _seedAction(db, id: 'zzz', role: 'done', text: 'z', doneAt: shared);
      await _seedAction(db, id: 'aaa', role: 'superseded', text: 'a',
          updatedAt: shared);
      await _seedAction(db, id: 'mmm', role: 'done', text: 'm', doneAt: shared);

      final history = await db.actionDao.getTerminatedActions('o1');

      expect(history.map((h) => h.action.id), ['aaa', 'mmm', 'zzz']);
    });

    test('carries per-Action logged minutes, not the Outcome total', () async {
      await _seedAction(db, id: 'a-done', role: 'done', text: 'finished',
          doneAt: _t0.add(const Duration(seconds: 60)));
      await _seedAction(db, id: 'b-super', role: 'superseded', text: 'dropped',
          updatedAt: _t0.add(const Duration(seconds: 30)));
      // 12 minutes against the done Action, 5 against the superseded one, plus a
      // legacy Outcome-grain row (NULL action_id) that belongs to neither.
      await _seedClosedLog(db, id: 'l1', actionId: 'a-done',
          startedAt: _t0, duration: const Duration(minutes: 12));
      await _seedClosedLog(db, id: 'l2', actionId: 'b-super',
          startedAt: _t0, duration: const Duration(minutes: 5));
      await _seedClosedLog(db, id: 'l3', actionId: null,
          startedAt: _t0, duration: const Duration(minutes: 99));

      final history = await db.actionDao.getTerminatedActions('o1');

      expect(
        {for (final h in history) h.action.id: h.loggedMinutes},
        {'a-done': 12, 'b-super': 5},
      );
    });

    test('logged minutes are 0 for an Action with no logs', () async {
      await _seedAction(db, id: 'a-done', role: 'done', text: 'finished',
          doneAt: _t0.add(const Duration(seconds: 60)));

      final history = await db.actionDao.getTerminatedActions('o1');

      expect(history.single.loggedMinutes, 0);
    });

    test('watchTerminatedActions emits the same shape as the one-shot read',
        () async {
      await _seedAction(db, id: 'a-done', role: 'done', text: 'finished',
          doneAt: _t0.add(const Duration(seconds: 60)));

      final emitted = await db.actionDao.watchTerminatedActions('o1').first;

      expect(emitted.map((h) => h.action.id),
          (await db.actionDao.getTerminatedActions('o1')).map((h) => h.action.id));
      expect(emitted, isA<List<TerminatedAction>>());
    });

    test('history is empty for an Outcome that never terminated an Action',
        () async {
      await _seedAction(db, id: 'a-current', role: 'current', text: 'now');

      expect(await db.actionDao.getTerminatedActions('o1'), isEmpty);
    });

    test('a read never stamps last_clarified_at', () async {
      await _seedAction(db, id: 'a-done', role: 'done', text: 'finished',
          doneAt: _t0.add(const Duration(seconds: 60)));
      final before = (await db.todoDao.getTodo('o1'))!.lastClarifiedAt;

      await db.actionDao.getTerminatedActions('o1');

      expect((await db.todoDao.getTodo('o1'))!.lastClarifiedAt, before,
          reason: 'reading history is not clarification');
    });

    test('abandon lands exactly one superseded row in history, no successor',
        () async {
      final t1 = _t0.add(const Duration(seconds: 10));
      final t2 = _t0.add(const Duration(seconds: 20));
      await db.actionDao.setCurrentAction('o1', 'the thing', now: t1);
      await db.actionDao.clearCurrentAction('o1', now: t2);

      final history = await db.actionDao.getTerminatedActions('o1');

      expect(history.length, 1);
      expect(history.single.action.actionText, 'the thing');
      expect(history.single.action.role, 'superseded');
      expect(await db.actionDao.getCurrentAction('o1'), isNull,
          reason: 'abandon mints no replacement');
    });

    test('abandon closes the open TimeLog and does not reopen one', () async {
      final t1 = _t0.add(const Duration(seconds: 10));
      final t2 = _t0.add(const Duration(minutes: 7, seconds: 10));
      await db.actionDao.setCurrentAction('o1', 'the thing', now: t1);
      await db.timeLogDao.openLog(taskId: 'o1', userId: _userId, now: t1);

      await db.actionDao.clearCurrentAction('o1', now: t2);

      final logs = await db.select(db.timeLogs).get();
      expect(logs.length, 1, reason: 'no continuation log — nothing to continue');
      expect(logs.single.endedAt, isNotNull);
      final history = await db.actionDao.getTerminatedActions('o1');
      expect(history.single.loggedMinutes, 7,
          reason: 'the abandoned Action keeps the time it earned');
    });
  });
}
