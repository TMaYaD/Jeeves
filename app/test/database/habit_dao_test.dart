import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/daos/habit_dao.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/habit_commitment.dart';
import 'package:jeeves/sync/collection_codecs.dart' show encodeInstant;
import 'package:jeeves/sync/domain_op_capture.dart';
import '../test_helpers.dart';

const _userId = 'test-user';

/// A fixed instant, so the stored text is the same on every run.
final _now = DateTime.utc(2026, 11, 18, 9, 30, 0, 123);
final _later = DateTime.utc(2026, 11, 19, 9, 30, 0, 456);

/// The first commitment of a Habit that is simply done every day.
const _everyDay = HabitCommitmentDraft(repeatKind: HabitRepeatKind.everyDay);

void main() {
  setUpAll(configureSqliteForTests);

  group('HabitDao', () {
    late RecordingDomainOpCapture capture;
    late GtdDatabase db;

    setUp(() {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      capture = RecordingDomainOpCapture();
      db = GtdDatabase(NativeDatabase.memory(), opCapture: capture);
    });
    tearDown(() async => db.close());

    Future<String> createHabit({
      String title = 'Read a book',
      String today = '2026-11-18',
      HabitCommitmentDraft commitment = _everyDay,
    }) =>
        db.habitDao.createHabit(
          userId: _userId,
          title: title,
          today: today,
          now: _now,
          firstCommitment: commitment,
        );

    group('create', () {
      test('creates a Habit with its first commitment and reads them back',
          () async {
        final habitId = await createHabit(title: '  Read a book  ');

        final habit = await db.habitDao.habitById(habitId);
        expect(habit, isNotNull);
        expect(habit!.title, 'Read a book');
        expect(habit.userId, _userId);
        expect(habit.anchorKind, 'none');
        expect(habit.anchorPartOfDay, isNull);
        expect(habit.anchorClockTime, isNull);
        expect(habit.anchorHabitId, isNull);
        expect(habit.createdAt, encodeInstant(_now));
        expect(habit.updatedAt, isNull);

        final commitments = await db.habitDao.commitmentsFor(habitId);
        expect(commitments, hasLength(1));
        expect(commitments.single.habitId, habitId);
        expect(commitments.single.repeatKind, HabitRepeatKind.everyDay);
        expect(commitments.single.chosenOn, '2026-11-18');
        expect(commitments.single.createdAt, _now);
        expect(commitments.single.isMeasurable, isFalse);
      });

      test('stores a measurable commitment as it was given', () async {
        final habitId = await createHabit(
          commitment: const HabitCommitmentDraft(
            repeatKind: HabitRepeatKind.timesPerWeek,
            timesPerPeriod: 3,
            preferredDays: [3, 1, 1],
            unitLabel: 'pages',
            dailyTargetAmount: 20,
          ),
        );

        final commitment =
            (await db.habitDao.commitmentsFor(habitId)).single;
        expect(commitment.repeatKind, HabitRepeatKind.timesPerWeek);
        expect(commitment.timesPerPeriod, 3);
        expect(commitment.preferredDays, [1, 3]);
        expect(commitment.unitLabel, 'pages');
        expect(commitment.dailyTargetAmount, 20);
        expect(commitment.isMeasurable, isTrue);
      });

      test('authors no op — the habit tables are local', () async {
        await createHabit();
        expect(capture.recorded, isEmpty);
      });

      test('refuses a Habit with no name', () async {
        await expectLater(
          createHabit(title: '   '),
          throwsArgumentError,
        );
      });

      test('refuses a name longer than 500 characters', () async {
        await expectLater(
          createHabit(title: 'x' * 501),
          throwsArgumentError,
        );
      });

      test('refuses a first commitment whose rule and target do not go '
          'together', () async {
        // A per-week commitment with no N.
        await expectLater(
          createHabit(
            commitment: const HabitCommitmentDraft(
              repeatKind: HabitRepeatKind.timesPerWeek,
            ),
          ),
          throwsArgumentError,
        );
        // A unit with no target.
        await expectLater(
          createHabit(
            commitment: const HabitCommitmentDraft(
              repeatKind: HabitRepeatKind.everyDay,
              unitLabel: 'pages',
            ),
          ),
          throwsArgumentError,
        );
      });

      test('writes no Habit when the first commitment is refused', () async {
        await expectLater(
          createHabit(
            commitment: const HabitCommitmentDraft(
              repeatKind: HabitRepeatKind.everyDay,
              dailyTargetAmount: 0,
            ),
          ),
          throwsArgumentError,
        );
        final habits = await db.select(db.habits).get();
        expect(habits, isEmpty);
      });
    });

    group('updateHabitDetails', () {
      test('writes the details and stamps updated_at', () async {
        final habitId = await createHabit();

        await db.habitDao.updateHabitDetails(
          habitId: habitId,
          userId: _userId,
          title: '  Read two books  ',
          notes: 'in the morning',
          energyLevel: 'medium',
          timeEstimateMinutes: 30,
          now: _later,
        );

        final habit = await db.habitDao.habitById(habitId);
        expect(habit!.title, 'Read two books');
        expect(habit.notes, 'in the morning');
        expect(habit.energyLevel, 'medium');
        expect(habit.timeEstimateMinutes, 30);
        expect(habit.updatedAt, encodeInstant(_later));
        // The rule is not the details' business.
        expect(await db.habitDao.commitmentsFor(habitId), hasLength(1));
      });

      test('clears a note and an estimate that are given as null', () async {
        final habitId = await createHabit();
        await db.habitDao.updateHabitDetails(
          habitId: habitId,
          userId: _userId,
          title: 'Read',
          notes: 'a note',
          energyLevel: 'low',
          timeEstimateMinutes: 15,
          now: _later,
        );

        await db.habitDao.updateHabitDetails(
          habitId: habitId,
          userId: _userId,
          title: 'Read',
          notes: null,
          energyLevel: null,
          timeEstimateMinutes: null,
          now: _later,
        );

        final habit = await db.habitDao.habitById(habitId);
        expect(habit!.notes, isNull);
        expect(habit.energyLevel, isNull);
        expect(habit.timeEstimateMinutes, isNull);
      });

      test('refuses an empty name', () async {
        final habitId = await createHabit();
        await expectLater(
          db.habitDao.updateHabitDetails(
            habitId: habitId,
            userId: _userId,
            title: '',
            notes: null,
            energyLevel: null,
            timeEstimateMinutes: null,
            now: _later,
          ),
          throwsArgumentError,
        );
        expect((await db.habitDao.habitById(habitId))!.title, 'Read a book');
      });

      test('refuses a name longer than 500 characters', () async {
        final habitId = await createHabit();
        await expectLater(
          db.habitDao.updateHabitDetails(
            habitId: habitId,
            userId: _userId,
            title: 'x' * 501,
            notes: null,
            energyLevel: null,
            timeEstimateMinutes: null,
            now: _later,
          ),
          throwsArgumentError,
        );
      });

      test('refuses an effort that is not low, medium or high', () async {
        final habitId = await createHabit();
        await expectLater(
          db.habitDao.updateHabitDetails(
            habitId: habitId,
            userId: _userId,
            title: 'Read',
            notes: null,
            energyLevel: 'enormous',
            timeEstimateMinutes: null,
            now: _later,
          ),
          throwsArgumentError,
        );
        final habit = await db.habitDao.habitById(habitId);
        expect(habit!.energyLevel, isNull);
        expect(habit.updatedAt, isNull);
      });

      test('refuses an estimate that is not more than zero minutes', () async {
        final habitId = await createHabit();
        await expectLater(
          db.habitDao.updateHabitDetails(
            habitId: habitId,
            userId: _userId,
            title: 'Read',
            notes: null,
            energyLevel: null,
            timeEstimateMinutes: 0,
            now: _later,
          ),
          throwsArgumentError,
        );
        await expectLater(
          db.habitDao.updateHabitDetails(
            habitId: habitId,
            userId: _userId,
            title: 'Read',
            notes: null,
            energyLevel: null,
            timeEstimateMinutes: -5,
            now: _later,
          ),
          throwsArgumentError,
        );
        expect((await db.habitDao.habitById(habitId))!.timeEstimateMinutes,
            isNull);
      });

      test('refuses a Habit that is not there', () async {
        await expectLater(
          db.habitDao.updateHabitDetails(
            habitId: 'no-such-habit',
            userId: _userId,
            title: 'Read',
            notes: null,
            energyLevel: null,
            timeEstimateMinutes: null,
            now: _later,
          ),
          throwsArgumentError,
        );
      });
    });

    group('setCommitment', () {
      test('keeps both commitments when the rule changes', () async {
        final habitId = await createHabit();

        await db.habitDao.setCommitment(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-19',
          now: _later,
          commitment: const HabitCommitmentDraft(
            repeatKind: HabitRepeatKind.timesPerWeek,
            timesPerPeriod: 3,
          ),
        );

        final commitments = await db.habitDao.commitmentsFor(habitId);
        expect(commitments, hasLength(2));
        expect(commitments.first.repeatKind, HabitRepeatKind.everyDay);
        expect(commitments.first.chosenOn, '2026-11-18');
        expect(commitments.last.repeatKind, HabitRepeatKind.timesPerWeek);
        expect(commitments.last.chosenOn, '2026-11-19');
        expect(commitments.last.createdAt, _later);
      });

      test('never rewrites an earlier commitment', () async {
        final habitId = await createHabit();
        final before = await db.habitDao.commitmentsFor(habitId);

        await db.habitDao.setCommitment(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-19',
          now: _later,
          commitment: const HabitCommitmentDraft(
            repeatKind: HabitRepeatKind.everyNDays,
            intervalDays: 2,
          ),
        );

        final after = await db.habitDao.commitmentsFor(habitId);
        expect(after.first.id, before.single.id);
        expect(after.first.repeatKind, before.single.repeatKind);
        expect(after.first.createdAt, before.single.createdAt);
      });

      test('stamps the Habit as edited', () async {
        final habitId = await createHabit();
        await db.habitDao.setCommitment(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-19',
          now: _later,
          commitment: const HabitCommitmentDraft(
            repeatKind: HabitRepeatKind.everyNDays,
            intervalDays: 2,
          ),
        );
        expect((await db.habitDao.habitById(habitId))!.updatedAt,
            encodeInstant(_later));
      });

      test('authors no op — the habit tables are local', () async {
        final habitId = await createHabit();
        await db.habitDao.setCommitment(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-19',
          now: _later,
          commitment: const HabitCommitmentDraft(
            repeatKind: HabitRepeatKind.everyNDays,
            intervalDays: 2,
          ),
        );
        expect(capture.recorded, isEmpty);
      });

      test('refuses a rule that does not hold together', () async {
        final habitId = await createHabit();
        await expectLater(
          db.habitDao.setCommitment(
            habitId: habitId,
            userId: _userId,
            today: '2026-11-19',
            now: _later,
            commitment: const HabitCommitmentDraft(
              repeatKind: HabitRepeatKind.everyNDays,
              intervalDays: 0,
            ),
          ),
          throwsArgumentError,
        );
        expect(await db.habitDao.commitmentsFor(habitId), hasLength(1));
      });

      test('refuses a Habit that is not there', () async {
        await expectLater(
          db.habitDao.setCommitment(
            habitId: 'no-such-habit',
            userId: _userId,
            today: '2026-11-19',
            now: _later,
            commitment: _everyDay,
          ),
          throwsArgumentError,
        );
      });
    });

    group('setAnchor', () {
      test('writes the anchor that matches the kind', () async {
        final habitId = await createHabit();

        await db.habitDao.setAnchor(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-18',
          now: _later,
          kind: HabitAnchorKind.partOfDay,
          partOfDay: 'morning',
        );
        var habit = await db.habitDao.habitById(habitId);
        expect(habit!.anchorKind, 'part_of_day');
        expect(habit.anchorPartOfDay, 'morning');
        expect(habit.anchorClockTime, isNull);
        expect(habit.anchorHabitId, isNull);

        await db.habitDao.setAnchor(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-18',
          now: _later,
          kind: HabitAnchorKind.clockTime,
          clockTime: '07:30',
        );
        habit = await db.habitDao.habitById(habitId);
        expect(habit!.anchorKind, 'clock_time');
        expect(habit.anchorClockTime, '07:30');
        expect(habit.anchorPartOfDay, isNull);

        await db.habitDao.setAnchor(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-18',
          now: _later,
          kind: HabitAnchorKind.none,
        );
        habit = await db.habitDao.habitById(habitId);
        expect(habit!.anchorKind, 'none');
        expect(habit.anchorPartOfDay, isNull);
        expect(habit.anchorClockTime, isNull);
        expect(habit.anchorHabitId, isNull);
      });

      test('anchors a Habit after another Habit', () async {
        final first = await createHabit(title: 'First');
        final second = await createHabit(title: 'Second');

        await db.habitDao.setAnchor(
          habitId: first,
          userId: _userId,
          today: '2026-11-18',
          now: _later,
          kind: HabitAnchorKind.afterHabit,
          anchorHabitId: second,
        );

        final habit = await db.habitDao.habitById(first);
        expect(habit!.anchorKind, 'after_habit');
        expect(habit.anchorHabitId, second);
        expect(habit.updatedAt, encodeInstant(_later));
      });

      test('refuses an anchor value that does not match the kind', () async {
        final habitId = await createHabit();

        // A part of the day with a clock time as well.
        await expectLater(
          db.habitDao.setAnchor(
            habitId: habitId,
            userId: _userId,
            today: '2026-11-18',
            now: _later,
            kind: HabitAnchorKind.partOfDay,
            partOfDay: 'morning',
            clockTime: '07:30',
          ),
          throwsArgumentError,
        );
        // An unanchored Habit with a part of the day.
        await expectLater(
          db.habitDao.setAnchor(
            habitId: habitId,
            userId: _userId,
            today: '2026-11-18',
            now: _later,
            kind: HabitAnchorKind.none,
            partOfDay: 'morning',
          ),
          throwsArgumentError,
        );
        // A part of the day that is not one of the three.
        await expectLater(
          db.habitDao.setAnchor(
            habitId: habitId,
            userId: _userId,
            today: '2026-11-18',
            now: _later,
            kind: HabitAnchorKind.partOfDay,
            partOfDay: 'night',
          ),
          throwsArgumentError,
        );
        // A clock time that is not a local HH:MM.
        await expectLater(
          db.habitDao.setAnchor(
            habitId: habitId,
            userId: _userId,
            today: '2026-11-18',
            now: _later,
            kind: HabitAnchorKind.clockTime,
            clockTime: '25:00',
          ),
          throwsArgumentError,
        );
        // An anchor on another Habit with no Habit named.
        await expectLater(
          db.habitDao.setAnchor(
            habitId: habitId,
            userId: _userId,
            today: '2026-11-18',
            now: _later,
            kind: HabitAnchorKind.afterHabit,
          ),
          throwsArgumentError,
        );

        final habit = await db.habitDao.habitById(habitId);
        expect(habit!.anchorKind, 'none');
        expect(habit.updatedAt, isNull);
      });

      test('refuses an anchor on itself', () async {
        final habitId = await createHabit();
        await expectLater(
          db.habitDao.setAnchor(
            habitId: habitId,
            userId: _userId,
            today: '2026-11-18',
            now: _later,
            kind: HabitAnchorKind.afterHabit,
            anchorHabitId: habitId,
          ),
          throwsArgumentError,
        );
      });

      test('refuses an anchor on a Habit that is not there', () async {
        final habitId = await createHabit();
        await expectLater(
          db.habitDao.setAnchor(
            habitId: habitId,
            userId: _userId,
            today: '2026-11-18',
            now: _later,
            kind: HabitAnchorKind.beforeHabit,
            anchorHabitId: 'no-such-habit',
          ),
          throwsArgumentError,
        );
      });

      test('refuses an anchor on an archived Habit', () async {
        final habitId = await createHabit(title: 'First');
        final archived = await createHabit(title: 'Archived');
        await db.into(db.habitInactivePeriods).insert(
              HabitInactivePeriodsCompanion.insert(
                id: const Value('period-1'),
                userId: _userId,
                habitId: archived,
                kind: 'archived',
                startsOn: '2026-11-01',
              ),
            );

        await expectLater(
          db.habitDao.setAnchor(
            habitId: habitId,
            userId: _userId,
            today: '2026-11-18',
            now: _later,
            kind: HabitAnchorKind.afterHabit,
            anchorHabitId: archived,
          ),
          throwsArgumentError,
        );
        expect((await db.habitDao.habitById(habitId))!.anchorHabitId, isNull);
      });

      test('refuses an anchor that would loop back', () async {
        final a = await createHabit(title: 'A');
        final b = await createHabit(title: 'B');

        await db.habitDao.setAnchor(
          habitId: a,
          userId: _userId,
          today: '2026-11-18',
          now: _later,
          kind: HabitAnchorKind.afterHabit,
          anchorHabitId: b,
        );

        await expectLater(
          db.habitDao.setAnchor(
            habitId: b,
            userId: _userId,
            today: '2026-11-18',
            now: _later,
            kind: HabitAnchorKind.afterHabit,
            anchorHabitId: a,
          ),
          throwsArgumentError,
        );
        expect((await db.habitDao.habitById(b))!.anchorHabitId, isNull);
      });

      test('refuses an anchor that would loop back through another Habit',
          () async {
        final a = await createHabit(title: 'A');
        final b = await createHabit(title: 'B');
        final c = await createHabit(title: 'C');

        await db.habitDao.setAnchor(
          habitId: a,
          userId: _userId,
          today: '2026-11-18',
          now: _later,
          kind: HabitAnchorKind.afterHabit,
          anchorHabitId: b,
        );
        await db.habitDao.setAnchor(
          habitId: b,
          userId: _userId,
          today: '2026-11-18',
          now: _later,
          kind: HabitAnchorKind.afterHabit,
          anchorHabitId: c,
        );

        await expectLater(
          db.habitDao.setAnchor(
            habitId: c,
            userId: _userId,
            today: '2026-11-18',
            now: _later,
            kind: HabitAnchorKind.afterHabit,
            anchorHabitId: a,
          ),
          throwsArgumentError,
        );
        expect((await db.habitDao.habitById(c))!.anchorHabitId, isNull);
      });

      test('allows an anchor that does not loop', () async {
        final a = await createHabit(title: 'A');
        final b = await createHabit(title: 'B');
        final c = await createHabit(title: 'C');

        await db.habitDao.setAnchor(
          habitId: a,
          userId: _userId,
          today: '2026-11-18',
          now: _later,
          kind: HabitAnchorKind.afterHabit,
          anchorHabitId: b,
        );
        // A follows B, B follows C — and A may follow C all the same, because
        // C does not follow A.
        await db.habitDao.setAnchor(
          habitId: a,
          userId: _userId,
          today: '2026-11-18',
          now: _later,
          kind: HabitAnchorKind.afterHabit,
          anchorHabitId: c,
        );
        expect((await db.habitDao.habitById(a))!.anchorHabitId, c);
      });
    });
  });
}
