import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/daos/habit_dao.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/habit_commitment.dart';
import 'package:jeeves/sync/domain_op_capture.dart';
import '../test_helpers.dart';

const _userId = 'test-user';
final _t0 = DateTime(2026, 11, 18, 9, 0, 0);

void main() {
  setUpAll(configureSqliteForTests);

  group('HabitFocusDao', () {
    late RecordingDomainOpCapture capture;
    late GtdDatabase db;

    setUp(() {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      capture = RecordingDomainOpCapture();
      db = GtdDatabase(NativeDatabase.memory(), opCapture: capture);
    });
    tearDown(() async => db.close());

    Future<String> createHabit({String title = 'Meditate', int? estimate = 10}) async {
      final id = await db.habitDao.createHabit(
        userId: _userId,
        title: title,
        today: '2026-11-18',
        now: _t0,
        firstCommitment:
            const HabitCommitmentDraft(repeatKind: HabitRepeatKind.everyDay),
      );
      if (estimate != null) {
        await db.habitDao.updateHabitDetails(
          habitId: id,
          userId: _userId,
          title: title,
          notes: null,
          energyLevel: null,
          timeEstimateMinutes: estimate,
          now: _t0,
        );
      }
      return id;
    }

    test('openHabitFocus opens one log and sprint 1, and closes a previous '
        'open habit log', () async {
      final first = await createHabit();
      final second = await createHabit(title: 'Journal');
      await db.habitFocusDao.openHabitFocus(
          habitId: first, userId: _userId, plannedSprintMinutes: 25, now: _t0);
      final logs = await db.select(db.habitTimeLogs).get();
      final sprints = await db.select(db.habitSprints).get();
      expect(logs, hasLength(1));
      expect(logs.single.habitId, first);
      expect(logs.single.endedAt, isNull);
      expect(sprints, hasLength(1));
      expect(sprints.single.plannedDurationMinutes, 25);

      final later = _t0.add(const Duration(minutes: 3));
      await db.habitFocusDao.openHabitFocus(
          habitId: second, userId: _userId, plannedSprintMinutes: 25, now: later);
      final after = await db.select(db.habitTimeLogs).get();
      expect(after, hasLength(2));
      expect(after.where((l) => l.endedAt == null), hasLength(1));
      expect(after.singleWhere((l) => l.habitId == first).endedAt, isNotNull);
      final sprintsAfter = await db.select(db.habitSprints).get();
      expect(sprintsAfter.where((s) => s.endedAt == null), hasLength(1));
      expect(sprintsAfter.singleWhere((s) => s.habitId == first).endedAt,
          isNotNull);
    });

    test('refuses a Habit with no estimate and a paused Habit', () async {
      final noEstimate = await createHabit(title: 'Water', estimate: null);
      await expectLater(
          db.habitFocusDao.openHabitFocus(
              habitId: noEstimate,
              userId: _userId,
              plannedSprintMinutes: 25,
              now: _t0),
          throwsStateError);
      final paused = await createHabit(title: 'Stretch');
      await db.habitDao.pause(
          habitId: paused, userId: _userId, today: '2026-11-18', now: _t0);
      await expectLater(
          db.habitFocusDao.openHabitFocus(
              habitId: paused,
              userId: _userId,
              plannedSprintMinutes: 25,
              now: _t0),
          throwsStateError);
      expect(await db.select(db.habitTimeLogs).get(), isEmpty);
      expect(await db.select(db.habitSprints).get(), isEmpty);
    });

    test('startHabitSprint ends the running sprint and starts the next',
        () async {
      final habit = await createHabit();
      await db.habitFocusDao.openHabitFocus(
          habitId: habit, userId: _userId, plannedSprintMinutes: 25, now: _t0);
      await db.habitFocusDao.endRunningHabitSprint(
          userId: _userId, now: _t0.add(const Duration(minutes: 25)));
      await db.habitFocusDao.startHabitSprint(
          userId: _userId,
          plannedSprintMinutes: 25,
          now: _t0.add(const Duration(minutes: 30)));
      final sprints = await db.select(db.habitSprints).get();
      expect(sprints, hasLength(2));
      expect(sprints.where((s) => s.endedAt == null), hasLength(1));
      final records =
          await db.habitFocusDao.watchHabitFocusRecords(habit).first;
      expect(records.openLog, isNotNull);
      expect(records.sprints, hasLength(2));
    });

    test('closeHabitFocus ends the running sprint and the log', () async {
      final habit = await createHabit();
      await db.habitFocusDao.openHabitFocus(
          habitId: habit, userId: _userId, plannedSprintMinutes: 25, now: _t0);
      await db.habitFocusDao.closeHabitFocus(
          userId: _userId, now: _t0.add(const Duration(minutes: 5)));
      expect((await db.select(db.habitTimeLogs).get()).single.endedAt,
          isNotNull);
      expect((await db.select(db.habitSprints).get()).single.endedAt,
          isNotNull);
      expect(await db.habitFocusDao.openHabitTimeLog(_userId), isNull);
      // A second close writes nothing and does not throw.
      await db.habitFocusDao.closeHabitFocus(userId: _userId, now: _t0);
    });

    test('opening a Focus ends an Outcome engagement still open in the store',
        () async {
      final habit = await createHabit();
      await db.todoDao.insertOutcome(
          id: 'outcome-1', title: 'Write', userId: _userId, now: _t0);
      await db.timeLogDao.openLog(taskId: 'outcome-1', userId: _userId, now: _t0);
      final later = _t0.add(const Duration(minutes: 5));
      await db.habitFocusDao.openHabitFocus(
          habitId: habit, userId: _userId, plannedSprintMinutes: 25, now: later);
      final outcomeLog = (await db.select(db.timeLogs).get()).single;
      expect(outcomeLog.endedAt, isNotNull);
      expect(await db.habitFocusDao.openHabitTimeLog(_userId), isNotNull);
    });

    test('a rejected Habit leaves an Outcome engagement running', () async {
      final noEstimate = await createHabit(estimate: null);
      await db.todoDao.insertOutcome(
          id: 'outcome-1', title: 'Write', userId: _userId, now: _t0);
      await db.timeLogDao.openLog(taskId: 'outcome-1', userId: _userId, now: _t0);
      await expectLater(
        db.habitFocusDao.openHabitFocus(
            habitId: noEstimate,
            userId: _userId,
            plannedSprintMinutes: 25,
            now: _t0),
        throwsStateError,
      );
      expect((await db.select(db.timeLogs).get()).single.endedAt, isNull);
    });

    test('the Focus records stream follows a Sprint starting', () async {
      final habit = await createHabit();
      await db.habitFocusDao.openHabitFocus(
          habitId: habit, userId: _userId, plannedSprintMinutes: 25, now: _t0);
      final counts = <int>[];
      final sub = db.habitFocusDao
          .watchHabitFocusRecords(habit)
          .listen((records) => counts.add(records.sprints.length));
      addTearDown(sub.cancel);
      await pumpEventQueue();
      await db.habitFocusDao.startHabitSprint(
          userId: _userId,
          plannedSprintMinutes: 25,
          now: _t0.add(const Duration(minutes: 30)));
      await pumpEventQueue();
      expect(counts.last, 2);
    });

    test('never writes a time_logs or sprints row, nor an op', () async {
      final habit = await createHabit();
      final opsBefore = capture.recorded.length;
      await db.habitFocusDao.openHabitFocus(
          habitId: habit, userId: _userId, plannedSprintMinutes: 25, now: _t0);
      await db.habitFocusDao.closeHabitFocus(userId: _userId, now: _t0);
      expect(await db.select(db.timeLogs).get(), isEmpty);
      expect(await db.select(db.sprints).get(), isEmpty);
      expect(capture.recorded.length, opsBefore);
    });
  });
}
