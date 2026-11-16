/// The recorded Sprint (issue #910): what [SprintDao] writes and captures, the
/// effective end it derives, and the five places a Sprint ends with its TimeLog.
@TestOn('!browser')
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/daos/action_dao.dart';
import 'package:jeeves/database/daos/sprint_dao.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/sync/collection_codecs.dart';
import 'package:jeeves/sync/domain_op_capture.dart';

import '../test_helpers.dart';

const _userId = 'sprint-user';
final _t0 = DateTime.utc(2026, 7, 28, 9);
DateTime _at(int minutes) => _t0.add(Duration(minutes: minutes));

Sprint _row(String id, DateTime start, {DateTime? end, String user = _userId}) =>
    Sprint(
      id: id,
      userId: user,
      actionId: 'action-1',
      startedAt: encodeInstant(start)!,
      endedAt: encodeInstant(end),
      plannedDurationMinutes: 25,
    );

void main() {
  setUpAll(configureSqliteForTests);

  group('sprintRecordsWithEffectiveEnds', () {
    test('an open Sprint with a later one reads as ending 1 ms before it', () {
      final records = sprintRecordsWithEffectiveEnds([
        _row('b', _at(10)),
        _row('a', _at(0)),
      ]);
      expect([for (final r in records) r.id], ['a', 'b']);
      expect(records.first.endedAtUtc, _at(10).subtract(const Duration(milliseconds: 1)));
      expect(records.first.storedEndedAtUtc, isNull);
      expect(records.last.isRunning, isTrue);
    });

    test('a stored end beats the derivation', () {
      final records = sprintRecordsWithEffectiveEnds([
        _row('a', _at(0), end: _at(20)),
        _row('b', _at(10)),
      ]);
      expect(records.first.endedAtUtc, _at(20));
    });

    test('equal starts order by id, so every device derives the same ends', () {
      final records = sprintRecordsWithEffectiveEnds([
        _row('b', _at(0)),
        _row('a', _at(0)),
      ]);
      expect(records.first.id, 'a');
      expect(records.first.endedAtUtc, _at(0).subtract(const Duration(milliseconds: 1)));
      expect(records.last.isRunning, isTrue);
    });

    test('another user\'s Sprint is not "the next Sprint"', () {
      final records = sprintRecordsWithEffectiveEnds([
        _row('a', _at(0)),
        _row('b', _at(10), user: 'someone-else'),
      ]);
      expect(records.first.isRunning, isTrue);
    });
  });

  group('SprintDao', () {
    late RecordingDomainOpCapture capture;
    late GtdDatabase db;

    setUp(() {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      capture = RecordingDomainOpCapture();
      db = GtdDatabase(NativeDatabase.memory(), opCapture: capture);
    });
    tearDown(() async => db.close());

    Future<String> seedOutcome() async {
      await db.todoDao.insertOutcome(
          id: 'outcome-1', title: 'Write', userId: _userId, now: _t0);
      capture.clear();
      return 'outcome-1';
    }

    Future<List<Sprint>> rows() => db.select(db.sprints).get();

    test('startSprint records the whole row on the current Action and captures it',
        () async {
      final outcome = await seedOutcome();
      final id = await db.sprintDao.startSprint(
        taskId: outcome,
        userId: _userId,
        plannedDurationMinutes: 25,
        now: _t0,
      );
      final stored = (await rows()).single;
      expect(stored.id, id);
      expect(stored.startedAt, encodeInstant(_t0));
      expect(stored.endedAt, isNull);
      expect(stored.plannedDurationMinutes, 25);
      expect(stored.actionId, isNotNull);

      final ops = capture.forCollection(sprintsCollection);
      expect(ops, hasLength(1));
      expect(ops.single.fields.keys.toSet(),
          collectionCodecs[sprintsCollection]!.columns.keys.toSet());
      expect(ops.single.fields['action_id'], stored.actionId);
    });

    test('starting a Sprint ends the running one at the same instant', () async {
      final outcome = await seedOutcome();
      await db.sprintDao.startSprint(
          taskId: outcome, userId: _userId, plannedDurationMinutes: 25, now: _t0);
      await db.sprintDao.startSprint(
          taskId: outcome,
          userId: _userId,
          plannedDurationMinutes: 25,
          now: _at(30));
      final stored = await rows();
      expect(stored, hasLength(2));
      expect(stored.where((r) => r.endedAt == null), hasLength(1));
      expect(stored.firstWhere((r) => r.endedAt != null).endedAt,
          encodeInstant(_at(30)));
    });

    test('the first end stands: a second end writes and captures nothing',
        () async {
      final outcome = await seedOutcome();
      await db.sprintDao.startSprint(
          taskId: outcome, userId: _userId, plannedDurationMinutes: 25, now: _t0);
      await db.sprintDao.endRunningSprint(userId: _userId, now: _at(20));
      capture.clear();
      await db.sprintDao.endRunningSprint(userId: _userId, now: _at(40));
      expect((await rows()).single.endedAt, encodeInstant(_at(20)));
      expect(capture.forCollection(sprintsCollection), isEmpty);
    });

    test('instants are millisecond-truncated, so the row equals what peers get',
        () async {
      final outcome = await seedOutcome();
      await db.sprintDao.startSprint(
        taskId: outcome,
        userId: _userId,
        plannedDurationMinutes: 25,
        now: DateTime.utc(2026, 7, 28, 9, 0, 0, 123, 987),
      );
      expect((await rows()).single.startedAt, '2026-07-28T09:00:00.123Z');
    });

    group('a Sprint never outlives its TimeLog', () {
      Future<String> runningSprint() async {
        final outcome = await seedOutcome();
        await db.timeLogDao.openLog(taskId: outcome, userId: _userId, now: _t0);
        await db.sprintDao.startSprint(
            taskId: outcome,
            userId: _userId,
            plannedDurationMinutes: 25,
            now: _t0);
        capture.clear();
        return outcome;
      }

      Future<void> expectEndedAt(DateTime at) async {
        expect((await rows()).single.endedAt, encodeInstant(at));
        final ops = capture.forCollection(sprintsCollection);
        expect(ops, hasLength(1));
        expect(ops.single.fields, {'ended_at': encodeInstant(at)});
      }

      test('TimeLogDao.closeLog', () async {
        final outcome = await runningSprint();
        await db.timeLogDao.closeLog(taskId: outcome, now: _at(7));
        await expectEndedAt(_at(7));
      });

      test('TimeLogDao.openLog closing the previous stint', () async {
        await runningSprint();
        await db.todoDao.insertOutcome(
            id: 'outcome-2', title: 'Other', userId: _userId, now: _t0);
        await db.timeLogDao
            .openLog(taskId: 'outcome-2', userId: _userId, now: _at(9));
        expect((await rows()).single.endedAt, encodeInstant(_at(9)));
      });

      test('FocusSessionDao.setCurrentTask clearing the task', () async {
        final outcome = await seedOutcome();
        final sessionId = await db.focusSessionDao
            .openSession(userId: _userId, taskIds: [outcome], now: _t0);
        await db.focusSessionDao
            .setCurrentTask(sessionId: sessionId, taskId: outcome, now: _t0);
        await db.sprintDao.startSprint(
            taskId: outcome,
            userId: _userId,
            plannedDurationMinutes: 25,
            now: _t0);
        capture.clear();
        await db.focusSessionDao
            .setCurrentTask(sessionId: sessionId, taskId: null, now: _at(11));
        await expectEndedAt(_at(11));
      });

      test('FocusSessionDao.closeSession', () async {
        final outcome = await seedOutcome();
        final sessionId = await db.focusSessionDao
            .openSession(userId: _userId, taskIds: [outcome], now: _t0);
        await db.focusSessionDao
            .setCurrentTask(sessionId: sessionId, taskId: outcome, now: _t0);
        await db.sprintDao.startSprint(
            taskId: outcome,
            userId: _userId,
            plannedDurationMinutes: 25,
            now: _t0);
        capture.clear();
        await db.focusSessionDao.closeSession(sessionId: sessionId, now: _at(12));
        await expectEndedAt(_at(12));
      });

      test('ActionDao.completeCurrentAction', () async {
        final outcome = await runningSprint();
        await db.actionDao.completeCurrentAction(outcome, now: _at(13));
        await expectEndedAt(_at(13));
      });
    });

    test('closing a TimeLog changes no TimeLog arithmetic', () async {
      final outcome = await seedOutcome();
      await db.timeLogDao.openLog(taskId: outcome, userId: _userId, now: _t0);
      await db.sprintDao.startSprint(
          taskId: outcome, userId: _userId, plannedDurationMinutes: 25, now: _t0);
      await db.sprintDao.endRunningSprint(userId: _userId, now: _at(25));
      await db.timeLogDao.closeLog(taskId: outcome, now: _at(30));
      expect(await db.timeLogDao.totalMinutesForTask(outcome), 30,
          reason: 'the break between Sprints still counts');
    });

    test(
        "closing one TimeLog leaves the same user's Sprint of another open "
        'TimeLog running', () async {
      // Device one: an open TimeLog and its Sprint on outcome-1.
      final outcome = await seedOutcome();
      await db.timeLogDao.openLog(taskId: outcome, userId: _userId, now: _t0);
      await db.sprintDao.startSprint(
          taskId: outcome, userId: _userId, plannedDurationMinutes: 25, now: _t0);
      // Device two, offline: its own open TimeLog and later Sprint on
      // outcome-2, converged in without going through openLog.
      await db.todoDao.insertOutcome(
          id: 'outcome-2', title: 'Other', userId: _userId, now: _t0);
      final other = await db.capturing(() =>
          ActionDao.ensureCurrentActionIdFor(db, 'outcome-2', _at(2)));
      await db.into(db.timeLogs).insert(TimeLogsCompanion.insert(
          id: 'log-2',
          userId: _userId,
          taskId: 'outcome-2',
          actionId: Value(other.actionId),
          startedAt: _at(2).toIso8601String()));
      await db.into(db.sprints).insert(SprintsCompanion.insert(
          id: 'sprint-2',
          userId: _userId,
          actionId: Value(other.actionId),
          startedAt: encodeInstant(_at(2))!,
          plannedDurationMinutes: 25));

      await db.timeLogDao.closeLog(taskId: outcome, now: _at(7));

      final all = await rows();
      expect(all.firstWhere((r) => r.id != 'sprint-2').endedAt,
          encodeInstant(_at(7)));
      expect(all.firstWhere((r) => r.id == 'sprint-2').endedAt, isNull,
          reason: "the other TimeLog's Sprint keeps running");
    });

    test("closing one user's Sprint leaves another user's open", () async {
      final outcome = await seedOutcome();
      await db.sprintDao.startSprint(
          taskId: outcome, userId: _userId, plannedDurationMinutes: 25, now: _t0);
      await db.sprintDao.startSprint(
          taskId: outcome,
          userId: 'other-user',
          plannedDurationMinutes: 25,
          now: _at(1));
      await db.sprintDao.endRunningSprint(userId: _userId, now: _at(5));
      final rows = await db.select(db.sprints).get();
      expect(rows.where((r) => r.userId == _userId).single.endedAt, isNotNull);
      expect(rows.where((r) => r.userId == 'other-user').single.endedAt,
          isNull);
    });

    test('deleting an Outcome detaches its Sprints instead of deleting them',
        () async {
      final outcome = await seedOutcome();
      await db.sprintDao.startSprint(
          taskId: outcome, userId: _userId, plannedDurationMinutes: 25, now: _t0);
      capture.clear();
      await db.todoDao.deleteOutcome(outcome);
      final ops = capture.forCollection(sprintsCollection);
      expect(ops, hasLength(1));
      expect(ops.single.fields, {'action_id': null});
      expect(await db.select(db.sprints).get(), hasLength(1),
          reason: 'the Sprint row is kept, only detached');
    });
  });
}
