import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/daos/habit_dao.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/habit_commitment.dart';
import 'package:jeeves/sync/domain_op_capture.dart';
import '../test_helpers.dart';

const _userId = 'test-user';

/// The journey of one Habit through its whole life: checked in, retargeted,
/// paused, archived, restored — and then the app is closed and opened again.
///
/// The store is a **file**, not a memory database, because the claim under
/// test is that the rows survive a restart of the app: the file is what a
/// device keeps.
void main() {
  setUpAll(configureSqliteForTests);

  group('a Habit\'s history survives a restart', () {
    late Directory storeDirectory;
    late String storePath;
    late GtdDatabase db;
    late RecordingDomainOpCapture capture;

    setUp(() async {
      storeDirectory = await Directory.systemTemp.createTemp('jeeves-habits');
      storePath = '${storeDirectory.path}/habits.sqlite';
      capture = RecordingDomainOpCapture();
      db = GtdDatabase(NativeDatabase(File(storePath)), opCapture: capture);
    });

    tearDown(() async {
      await db.close();
      if (storeDirectory.existsSync()) {
        await storeDirectory.delete(recursive: true);
      }
    });

    test('the Check-ins, the commitments and the periods are all still there',
        () async {
      final now = DateTime.utc(2026, 11, 1, 8, 0, 0);
      // The target change is written later than the commitment it replaces:
      // "the commitment in force" is the most recently **created** one, and
      // two commitments written at the same instant are told apart by an id.
      final retargeted = DateTime.utc(2026, 11, 4, 8, 0, 0);

      final habitId = await db.habitDao.createHabit(
        userId: _userId,
        title: 'Read a book',
        today: '2026-11-01',
        now: now,
        firstCommitment: const HabitCommitmentDraft(
          repeatKind: HabitRepeatKind.everyDay,
        ),
      );

      // Three days of Check-ins on the binary Habit.
      for (final day in const ['2026-11-01', '2026-11-02', '2026-11-03']) {
        await db.habitDao.addCheckIn(
          habitId: habitId,
          userId: _userId,
          countsForDay: day,
          now: now,
        );
      }

      // The target changes on the fourth day.
      await db.habitDao.setCommitment(
        habitId: habitId,
        userId: _userId,
        today: '2026-11-04',
        now: retargeted,
        commitment: const HabitCommitmentDraft(
          repeatKind: HabitRepeatKind.everyDay,
          unitLabel: 'pages',
          dailyTargetAmount: 20,
        ),
      );

      // Then the Habit is paused, archived and restored.
      await db.habitDao.pause(
        habitId: habitId,
        userId: _userId,
        today: '2026-11-05',
        now: now,
      );
      await db.habitDao.archive(
        habitId: habitId,
        userId: _userId,
        today: '2026-11-07',
        now: now,
      );
      await db.habitDao.restore(
        habitId: habitId,
        userId: _userId,
        today: '2026-11-09',
        now: now,
      );

      // The habit tables are local: nothing here is on the wire.
      expect(capture.recorded, isEmpty);

      // Close the store and open it again, as a restart of the app would.
      await db.close();
      db = GtdDatabase(NativeDatabase(File(storePath)));

      // Every Check-in is still there.
      final checkIns =
          await db.habitDao.checkInsFor(habitId, '2026-11-01', '2026-11-30');
      expect(checkIns, hasLength(3));
      expect(checkIns.map((c) => c.countsForDay),
          containsAllInOrder(['2026-11-01', '2026-11-02', '2026-11-03']));

      // Both commitments are still there.
      final commitments = await db.habitDao.commitmentsFor(habitId);
      expect(commitments, hasLength(2));

      // The days before the change still read the old target, and the days
      // after it read the new one.
      final before = commitmentInForceOn(commitments, '2026-11-03');
      expect(before, isNotNull);
      expect(before!.isMeasurable, isFalse);
      final after = commitmentInForceOn(commitments, '2026-11-04');
      expect(after, isNotNull);
      expect(after!.isMeasurable, isTrue);
      expect(after.unitLabel, 'pages');
      expect(after.dailyTargetAmount, 20);

      // The state is right for every period.
      expect(await db.habitDao.stateOn(habitId, '2026-11-04'),
          HabitState.active);
      expect(await db.habitDao.stateOn(habitId, '2026-11-05'),
          HabitState.paused);
      expect(await db.habitDao.stateOn(habitId, '2026-11-06'),
          HabitState.paused);
      expect(await db.habitDao.stateOn(habitId, '2026-11-07'),
          HabitState.archived);
      expect(await db.habitDao.stateOn(habitId, '2026-11-08'),
          HabitState.archived);
      expect(await db.habitDao.stateOn(habitId, '2026-11-09'),
          HabitState.active);
      expect(await db.habitDao.stateOn(habitId, '2026-11-10'),
          HabitState.active);
    });

    test('the Habit itself is still there', () async {
      final now = DateTime.utc(2026, 11, 1, 8, 0, 0);
      final habitId = await db.habitDao.createHabit(
        userId: _userId,
        title: 'Read a book',
        today: '2026-11-01',
        now: now,
        firstCommitment: const HabitCommitmentDraft(
          repeatKind: HabitRepeatKind.everyDay,
        ),
      );

      await db.close();
      db = GtdDatabase(NativeDatabase(File(storePath)));

      final habit = await db.habitDao.habitById(habitId);
      expect(habit, isNotNull);
      expect(habit!.title, 'Read a book');
      expect(habit.userId, _userId);
    });
  });
}
