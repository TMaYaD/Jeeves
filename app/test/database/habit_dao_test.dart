import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/daos/habit_dao.dart';
import 'package:jeeves/database/daos/place_dao.dart' show pinPlaceKind;
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/habit_commitment.dart';
import 'package:jeeves/models/habit_progress.dart' show HabitHistory;
import 'package:jeeves/models/place_area.dart';
import 'package:jeeves/sync/collection_codecs.dart'
    show encodeInstant, placesCollection;
import 'package:jeeves/sync/domain_op_capture.dart';
import '../test_helpers.dart';

const _userId = 'test-user';

/// A fixed instant, so the stored text is the same on every run.
final _now = DateTime.utc(2026, 11, 18, 9, 30, 0, 123);
final _later = DateTime.utc(2026, 11, 19, 9, 30, 0, 456);

/// The first commitment of a Habit that is simply done every day.
const _everyDay = HabitCommitmentDraft(repeatKind: HabitRepeatKind.everyDay);

/// The first commitment of a Habit that is measured against a target.
const _measurable = HabitCommitmentDraft(
  repeatKind: HabitRepeatKind.everyDay,
  unitLabel: 'pages',
  dailyTargetAmount: 20,
);

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
      DateTime? now,
    }) =>
        db.habitDao.createHabit(
          userId: _userId,
          title: title,
          today: today,
          now: now ?? _now,
          firstCommitment: commitment,
        );

    group('first Check-in of a day', () {
      test('adds only when the day has none, and a second call adds nothing',
          () async {
        final habitId = await createHabit();
        final first = await db.habitDao.addFirstCheckInOfDay(
            habitId: habitId,
            userId: _userId,
            countsForDay: '2026-11-18',
            now: _now);
        final second = await db.habitDao.addFirstCheckInOfDay(
            habitId: habitId,
            userId: _userId,
            countsForDay: '2026-11-18',
            now: _now);
        final both = await Future.wait([
          db.habitDao.addFirstCheckInOfDay(
              habitId: habitId,
              userId: _userId,
              countsForDay: '2026-11-19',
              now: _now),
          db.habitDao.addFirstCheckInOfDay(
              habitId: habitId,
              userId: _userId,
              countsForDay: '2026-11-19',
              now: _now),
        ]);

        expect(first, isNotNull);
        expect(second, isNull);
        expect(both.where((id) => id != null), hasLength(1));
        expect(await db.habitDao.checkInsFor(habitId, '2026-11-18', '2026-11-19'),
            hasLength(2));
      });
    });

    group('history reads', () {
      test('habitHistory gathers commitments, periods and Check-ins', () async {
        final habitId = await createHabit();
        await db.habitDao.addCheckIn(
            habitId: habitId,
            userId: _userId,
            countsForDay: '2026-11-18',
            now: _now);
        await db.habitDao.pause(
            habitId: habitId, userId: _userId, today: '2026-11-19', now: _later);

        final history = await db.habitDao.habitHistory(habitId);

        expect(history!.habit.id, habitId);
        expect(history.commitments, hasLength(1));
        expect(history.checkIns, hasLength(1));
        expect(history.inactivePeriods, hasLength(1));
        expect(await db.habitDao.inactivePeriodsFor(habitId), hasLength(1));
        expect(await db.habitDao.habitHistory('nope'), isNull);
      });

      test('watchHabitHistories emits again after a write to each table',
          () async {
        final habitId = await createHabit();
        final emissions = <List<HabitHistory>>[];
        final sub = db.habitDao.watchHabitHistories().listen(emissions.add);
        addTearDown(sub.cancel);

        Future<void> expectEmissionAfter(Future<void> Function() write) async {
          final before = emissions.length;
          await write();
          for (var i = 0; i < 100 && emissions.length == before; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(emissions.length, greaterThan(before));
        }

        await expectEmissionAfter(() async {});
        expect(emissions.last.single.checkIns, isEmpty);

        await expectEmissionAfter(() => db.habitDao.updateHabitDetails(
            habitId: habitId,
            userId: _userId,
            title: 'Read more',
            notes: null,
            energyLevel: null,
            timeEstimateMinutes: null,
            now: _later));
        expect(emissions.last.single.habit.title, 'Read more');

        // Inserted directly: setCommitment also stamps the habits row, which
        // would re-emit even without the commitments table being watched.
        await expectEmissionAfter(() => db.into(db.habitCommitments).insert(
            HabitCommitmentsCompanion.insert(
                userId: _userId,
                habitId: habitId,
                chosenOn: '2026-11-19',
                createdAt: encodeInstant(_later)!,
                repeatKind: 'every_day',
                unitLabel: const Value('glasses'),
                dailyTargetAmount: const Value(8))));
        expect(emissions.last.single.commitments, hasLength(2));

        await expectEmissionAfter(() => db.habitDao.addCheckIn(
            habitId: habitId,
            userId: _userId,
            countsForDay: '2026-11-19',
            now: _later,
            measuredAmount: 5));
        expect(emissions.last.single.checkIns, hasLength(1));

        await expectEmissionAfter(() => db.into(db.habitInactivePeriods).insert(
            HabitInactivePeriodsCompanion.insert(
                userId: _userId,
                habitId: habitId,
                kind: 'paused',
                startsOn: '2026-11-19')));
        expect(emissions.last.single.inactivePeriods, hasLength(1));
      });
    });

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

      test('a later commitment within one millisecond still wins', () async {
        final habitId = await createHabit();
        const weekly = HabitCommitmentDraft(
            repeatKind: HabitRepeatKind.timesPerWeek, timesPerPeriod: 2);
        const monthly = HabitCommitmentDraft(
            repeatKind: HabitRepeatKind.timesPerMonth, timesPerPeriod: 9);
        await db.habitDao.setCommitment(
            habitId: habitId, userId: _userId, today: '2026-11-18',
            now: _now, commitment: weekly);
        await db.habitDao.setCommitment(
            habitId: habitId, userId: _userId, today: '2026-11-18',
            now: _now, commitment: monthly);
        final commitments = await db.habitDao.commitmentsFor(habitId);
        expect(commitments, hasLength(3));
        // The write order is carried by strictly increasing creation times,
        // so the winner never depends on the random id.
        expect(commitments[0].createdAt.isBefore(commitments[1].createdAt),
            isTrue);
        expect(commitments[1].createdAt.isBefore(commitments[2].createdAt),
            isTrue);
        expect(commitments.map((c) => c.repeatKind), [
          HabitRepeatKind.everyDay,
          HabitRepeatKind.timesPerWeek,
          HabitRepeatKind.timesPerMonth,
        ]);
        expect(commitmentInForceOn(commitments, '2026-11-18')!.repeatKind,
            HabitRepeatKind.timesPerMonth);
      });

      test('refuses a new unit that reaches back to measured Check-ins',
          () async {
        final habitId = await createHabit(
          commitment: const HabitCommitmentDraft(
              repeatKind: HabitRepeatKind.everyDay,
              unitLabel: 'pages',
              dailyTargetAmount: 20),
        );
        await db.habitDao.addCheckIn(
            habitId: habitId, userId: _userId, countsForDay: '2026-11-18',
            now: _now, measuredAmount: 10);
        await expectLater(
          db.habitDao.setCommitment(
            habitId: habitId,
            userId: _userId,
            today: '2026-11-18',
            now: _later,
            commitment: const HabitCommitmentDraft(
                repeatKind: HabitRepeatKind.timesPerWeek,
                timesPerPeriod: 3,
                unitLabel: 'minutes',
                dailyTargetAmount: 30),
          ),
          throwsArgumentError,
        );
        // The same unit with a new target is still allowed.
        await db.habitDao.setCommitment(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-18',
          now: _later,
          commitment: const HabitCommitmentDraft(
              repeatKind: HabitRepeatKind.timesPerWeek,
              timesPerPeriod: 3,
              unitLabel: 'pages',
              dailyTargetAmount: 30),
        );
      });

      test('refuses a measurable commitment that reaches back to a binary Check-in',
          () async {
        final habitId = await createHabit();
        await db.habitDao.addCheckIn(
            habitId: habitId, userId: _userId, countsForDay: '2026-11-16',
            now: _now);
        await expectLater(
          db.habitDao.setCommitment(
            habitId: habitId,
            userId: _userId,
            today: '2026-11-18',
            now: _later,
            commitment: const HabitCommitmentDraft(
              repeatKind: HabitRepeatKind.timesPerWeek,
              timesPerPeriod: 3,
              unitLabel: 'pages',
              dailyTargetAmount: 20,
            ),
          ),
          throwsArgumentError,
        );
        expect(await db.habitDao.commitmentsFor(habitId), hasLength(1));
      });

      test('refuses a day key that is not canonical', () async {
        final habitId = await createHabit();
        await expectLater(
          db.habitDao.addCheckIn(
              habitId: habitId, userId: _userId,
              countsForDay: '2026-+1-+2', now: _now),
          throwsArgumentError,
        );
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
        await db.habitDao.setAnchor(
          habitId: b,
          userId: _userId,
          today: '2026-11-18',
          now: _later,
          kind: HabitAnchorKind.afterHabit,
          anchorHabitId: c,
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

    group('addCheckIn', () {
      test('keeps every Check-in made on one day', () async {
        final habitId = await createHabit();

        final first = await db.habitDao.addCheckIn(
          habitId: habitId,
          userId: _userId,
          countsForDay: '2026-11-18',
          now: _now,
        );
        final second = await db.habitDao.addCheckIn(
          habitId: habitId,
          userId: _userId,
          countsForDay: '2026-11-18',
          now: _later,
        );

        final checkIns =
            await db.habitDao.checkInsFor(habitId, '2026-11-18', '2026-11-18');
        expect(checkIns, hasLength(2));
        expect(checkIns.map((c) => c.id), containsAllInOrder([first, second]));
        expect(checkIns.every((c) => c.countsForDay == '2026-11-18'), isTrue);
      });

      test('a Check-in that is given its id is written once', () async {
        final habitId = await createHabit();

        final first = await db.habitDao.addCheckIn(
          habitId: habitId,
          userId: _userId,
          countsForDay: '2026-11-18',
          now: _now,
          checkInId: 'check-in-1',
        );
        expect(first, 'check-in-1');

        // The same Check-in again: the row is there, so nothing is written.
        final again = await db.habitDao.addCheckIn(
          habitId: habitId,
          userId: _userId,
          countsForDay: '2026-11-18',
          now: _now,
          checkInId: 'check-in-1',
        );
        expect(again, 'check-in-1');

        final checkIns =
            await db.habitDao.checkInsFor(habitId, '2026-11-18', '2026-11-18');
        expect(checkIns.map((c) => c.id), ['check-in-1']);
      });

      test('checks in on a day that is past', () async {
        final habitId = await createHabit(today: '2026-11-18');

        final id = await db.habitDao.addCheckIn(
          habitId: habitId,
          userId: _userId,
          countsForDay: '2026-11-10',
          now: _now,
        );

        final checkIns =
            await db.habitDao.checkInsFor(habitId, '2026-11-01', '2026-11-30');
        expect(checkIns.map((c) => c.id), [id]);
      });

      test('refuses an amount on a binary Habit\'s day', () async {
        final habitId = await createHabit();

        await expectLater(
          db.habitDao.addCheckIn(
            habitId: habitId,
            userId: _userId,
            countsForDay: '2026-11-18',
            now: _now,
            measuredAmount: 3,
          ),
          throwsArgumentError,
        );
        expect(
          await db.habitDao.checkInsFor(habitId, '2026-11-18', '2026-11-18'),
          isEmpty,
        );
      });

      test('refuses a missing amount on a measurable Habit\'s day', () async {
        final habitId = await createHabit(commitment: _measurable);

        await expectLater(
          db.habitDao.addCheckIn(
            habitId: habitId,
            userId: _userId,
            countsForDay: '2026-11-18',
            now: _now,
          ),
          throwsArgumentError,
        );
        expect(
          await db.habitDao.checkInsFor(habitId, '2026-11-18', '2026-11-18'),
          isEmpty,
        );
      });

      test('judges the day by the commitment in force', () async {
        // A binary Habit that becomes measurable on the third day.
        final habitId = await createHabit();
        await db.habitDao.setCommitment(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-20',
          now: _later,
          commitment: _measurable,
        );

        // Before the change the Habit is binary, so an amount is refused.
        await expectLater(
          db.habitDao.addCheckIn(
            habitId: habitId,
            userId: _userId,
            countsForDay: '2026-11-19',
            now: _now,
            measuredAmount: 5,
          ),
          throwsArgumentError,
        );
        // From the change on, it is measurable, so an amount is needed.
        await expectLater(
          db.habitDao.addCheckIn(
            habitId: habitId,
            userId: _userId,
            countsForDay: '2026-11-20',
            now: _now,
          ),
          throwsArgumentError,
        );
        await db.habitDao.addCheckIn(
          habitId: habitId,
          userId: _userId,
          countsForDay: '2026-11-20',
          now: _now,
          measuredAmount: 5,
        );
        expect(
          await db.habitDao.checkInsFor(habitId, '2026-11-20', '2026-11-20'),
          hasLength(1),
        );
      });

      test('authors no op — the habit tables are local', () async {
        final habitId = await createHabit();
        await db.habitDao.addCheckIn(
          habitId: habitId,
          userId: _userId,
          countsForDay: '2026-11-18',
          now: _now,
        );
        expect(capture.recorded, isEmpty);
      });

      test('refuses a Habit that is not there', () async {
        await expectLater(
          db.habitDao.addCheckIn(
            habitId: 'no-such-habit',
            userId: _userId,
            countsForDay: '2026-11-18',
            now: _now,
          ),
          throwsArgumentError,
        );
      });

      test('refuses a day that is not a day', () async {
        final habitId = await createHabit();
        await expectLater(
          db.habitDao.addCheckIn(
            habitId: habitId,
            userId: _userId,
            countsForDay: '18 November',
            now: _now,
          ),
          throwsArgumentError,
        );
      });
    });

    group('changeCheckInAmount and removeCheckIn', () {
      Future<String> checkInOf(String habitId) => db.habitDao.addCheckIn(
            habitId: habitId,
            userId: _userId,
            countsForDay: '2026-11-18',
            now: _now,
            measuredAmount: 5,
          );

      test('changes the amount of a Check-in', () async {
        final habitId = await createHabit(commitment: _measurable);
        final id = await checkInOf(habitId);

        await db.habitDao.changeCheckInAmount(
          checkInId: id,
          userId: _userId,
          measuredAmount: 12,
        );

        final checkIns =
            await db.habitDao.checkInsFor(habitId, '2026-11-18', '2026-11-18');
        expect(checkIns.single.measuredAmount, 12);
      });

      test('refuses an amount on a binary Habit', () async {
        final habitId = await createHabit();
        final id = await db.habitDao.addCheckIn(
          habitId: habitId,
          userId: _userId,
          countsForDay: '2026-11-18',
          now: _now,
        );

        await expectLater(
          db.habitDao.changeCheckInAmount(
            checkInId: id,
            userId: _userId,
            measuredAmount: 5,
          ),
          throwsArgumentError,
        );
      });

      test('refuses to drop the amount of a measurable Habit', () async {
        final habitId = await createHabit(commitment: _measurable);
        final id = await checkInOf(habitId);

        await expectLater(
          db.habitDao.changeCheckInAmount(
            checkInId: id,
            userId: _userId,
            measuredAmount: null,
          ),
          throwsArgumentError,
        );
        final checkIns =
            await db.habitDao.checkInsFor(habitId, '2026-11-18', '2026-11-18');
        expect(checkIns.single.measuredAmount, 5);
      });

      test('removes one Check-in and keeps the others', () async {
        final habitId = await createHabit();
        final first = await db.habitDao.addCheckIn(
          habitId: habitId,
          userId: _userId,
          countsForDay: '2026-11-18',
          now: _now,
        );
        final second = await db.habitDao.addCheckIn(
          habitId: habitId,
          userId: _userId,
          countsForDay: '2026-11-19',
          now: _later,
        );

        await db.habitDao.removeCheckIn(checkInId: first, userId: _userId);

        final checkIns =
            await db.habitDao.checkInsFor(habitId, '2026-11-18', '2026-11-19');
        expect(checkIns.map((c) => c.id), [second]);
      });

      test('refuses a Check-in that is not there', () async {
        await expectLater(
          db.habitDao.removeCheckIn(checkInId: 'no-such-check-in', userId: _userId),
          throwsArgumentError,
        );
      });
    });

    group('checkInsFor', () {
      test('gives the Check-ins of the range, oldest day first', () async {
        final habitId = await createHabit();
        await db.habitDao.addCheckIn(
          habitId: habitId,
          userId: _userId,
          countsForDay: '2026-11-20',
          now: _now,
        );
        await db.habitDao.addCheckIn(
          habitId: habitId,
          userId: _userId,
          countsForDay: '2026-11-18',
          now: _now,
        );
        await db.habitDao.addCheckIn(
          habitId: habitId,
          userId: _userId,
          countsForDay: '2026-11-19',
          now: _now,
        );

        final inRange =
            await db.habitDao.checkInsFor(habitId, '2026-11-19', '2026-11-20');
        expect(inRange.map((c) => c.countsForDay),
            ['2026-11-19', '2026-11-20']);

        final all = await db.habitDao.checkInsFor(habitId, '2026-11-01', '2026-11-30');
        expect(all.map((c) => c.countsForDay),
            containsAllInOrder(
                ['2026-11-18', '2026-11-19', '2026-11-20']));
      });

      test('is empty for a range that ends before it starts', () async {
        final habitId = await createHabit();
        await db.habitDao.addCheckIn(
          habitId: habitId,
          userId: _userId,
          countsForDay: '2026-11-18',
          now: _now,
        );

        expect(
          await db.habitDao.checkInsFor(habitId, '2026-11-20', '2026-11-10'),
          isEmpty,
        );
      });
    });

    group('pause, resume, archive and restore', () {
      test('refuses a pause that reaches into a later pause', () async {
        final habitId = await createHabit();
        await db.habitDao.pause(
            habitId: habitId, userId: _userId, today: '2026-11-25',
            now: _now, resumesOn: '2026-11-28');
        await expectLater(
          db.habitDao.pause(
              habitId: habitId, userId: _userId, today: '2026-11-20',
              now: _now, resumesOn: '2026-11-26'),
          throwsArgumentError,
        );
        // Ending on the day the next period starts is fine.
        await db.habitDao.pause(
            habitId: habitId, userId: _userId, today: '2026-11-20',
            now: _now, resumesOn: '2026-11-25');
        expect(await db.habitDao.stateOn(habitId, '2026-11-24'),
            HabitState.paused);
      });

      test('a pause resumed the day it started blocks no later pause or archive',
          () async {
        final habitId = await createHabit();
        await db.habitDao.pause(
            habitId: habitId, userId: _userId, today: '2026-11-25',
            now: _now, resumesOn: '2026-11-26');
        await db.habitDao.resume(
            habitId: habitId, userId: _userId, today: '2026-11-25', now: _now);
        // The empty period covers no days, so a pause across it is fine.
        await db.habitDao.pause(
            habitId: habitId, userId: _userId, today: '2026-11-20',
            now: _now, resumesOn: '2026-11-27');
        await db.habitDao.resume(
            habitId: habitId, userId: _userId, today: '2026-11-21', now: _now);
        await db.habitDao.archive(
            habitId: habitId, userId: _userId, today: '2026-11-22', now: _now);
        expect(await db.habitDao.stateOn(habitId, '2026-11-23'),
            HabitState.archived);
      });

      test('watchHabits refreshes an open subscription on a pause', () async {
        final habitId = await createHabit();
        final states = <HabitState>[];
        final subscription = db.habitDao
            .watchHabits('2026-11-19')
            .listen((rows) => states.add(rows.single.state));
        await pumpEventQueue();
        await db.habitDao.pause(
            habitId: habitId, userId: _userId, today: '2026-11-18',
            now: _now, resumesOn: '2026-11-25');
        await pumpEventQueue();
        await subscription.cancel();
        expect(states.first, HabitState.active);
        expect(states.last, HabitState.paused);
      });

      test('a commitment keeps the weekdays the caller submitted', () async {
        final habitId = await createHabit();
        final weekdays = [1, 3];
        final future = db.habitDao.setCommitment(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-18',
          now: _later,
          commitment: HabitCommitmentDraft(
              repeatKind: HabitRepeatKind.chosenWeekdays,
              chosenWeekdays: weekdays),
        );
        // The caller reuses its list while the write is pending.
        weekdays
          ..clear()
          ..add(5);
        await future;
        final commitments = await db.habitDao.commitmentsFor(habitId);
        expect(commitments.last.chosenWeekdays, [1, 3]);
      });

      test('a stored preferred-days text that does not decode skips the row',
          () async {
        final habitId = await createHabit();
        await db.habitDao.setCommitment(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-18',
          now: _later,
          commitment: const HabitCommitmentDraft(
              repeatKind: HabitRepeatKind.timesPerWeek, timesPerPeriod: 3),
        );
        await db.customStatement(
            "UPDATE habit_commitments SET preferred_days = '[1,\"Wed\"]' "
            "WHERE repeat_kind = 'times_per_week'");
        final commitments = await db.habitDao.commitmentsFor(habitId);
        expect(commitments.single.repeatKind, HabitRepeatKind.everyDay);
      });

      test('restore closes only the archive that covers the day', () async {
        final habitId = await createHabit();
        await db.habitDao.archive(
            habitId: habitId, userId: _userId, today: '2026-11-25', now: _now);
        await db.habitDao.archive(
            habitId: habitId, userId: _userId, today: '2026-11-20', now: _now);
        await db.habitDao.restore(
            habitId: habitId, userId: _userId, today: '2026-11-22', now: _now);
        expect(await db.habitDao.stateOn(habitId, '2026-11-22'),
            HabitState.active);
        expect(await db.habitDao.stateOn(habitId, '2026-11-26'),
            HabitState.archived);
      });

      test('watchHabits reads only the periods that cover the day', () async {
        final habitId = await createHabit();
        await db.habitDao.pause(
            habitId: habitId, userId: _userId, today: '2026-11-18',
            now: _now, resumesOn: '2026-11-20');
        final active = await db.habitDao.watchHabits('2026-11-25').first;
        expect(active.single.state, HabitState.active);
        final paused = await db.habitDao.watchHabits('2026-11-19').first;
        expect(paused.single.state, HabitState.paused);
      });

      test('a pause with an end date reads as active from that date', () async {
        final habitId = await createHabit();

        await db.habitDao.pause(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-18',
          now: _now,
          resumesOn: '2026-11-25',
        );

        expect(await db.habitDao.stateOn(habitId, '2026-11-17'),
            HabitState.active);
        expect(await db.habitDao.stateOn(habitId, '2026-11-18'),
            HabitState.paused);
        expect(await db.habitDao.stateOn(habitId, '2026-11-24'),
            HabitState.paused);
        expect(await db.habitDao.stateOn(habitId, '2026-11-25'),
            HabitState.active);
      });

      test('an open pause stays paused', () async {
        final habitId = await createHabit();

        await db.habitDao.pause(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-18',
          now: _now,
        );

        expect(await db.habitDao.stateOn(habitId, '2026-12-31'),
            HabitState.paused);
      });

      test('refuses a pause on a paused Habit', () async {
        final habitId = await createHabit();
        await db.habitDao.pause(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-18',
          now: _now,
        );

        await expectLater(
          db.habitDao.pause(
            habitId: habitId,
            userId: _userId,
            today: '2026-11-20',
            now: _later,
          ),
          throwsArgumentError,
        );
      });

      test('refuses a pause on an archived Habit', () async {
        final habitId = await createHabit();
        await db.habitDao.archive(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-18',
          now: _now,
        );

        await expectLater(
          db.habitDao.pause(
            habitId: habitId,
            userId: _userId,
            today: '2026-11-20',
            now: _later,
          ),
          throwsArgumentError,
        );
      });

      test('refuses a pause that ends on or before the day it starts', () async {
        final habitId = await createHabit();

        await expectLater(
          db.habitDao.pause(
            habitId: habitId,
            userId: _userId,
            today: '2026-11-18',
            now: _now,
            resumesOn: '2026-11-18',
          ),
          throwsArgumentError,
        );
        await expectLater(
          db.habitDao.pause(
            habitId: habitId,
            userId: _userId,
            today: '2026-11-18',
            now: _now,
            resumesOn: '2026-11-10',
          ),
          throwsArgumentError,
        );
        expect(await db.habitDao.stateOn(habitId, '2026-11-18'),
            HabitState.active);
      });

      test('resume ends a pause that still had an end date ahead', () async {
        final habitId = await createHabit();
        await db.habitDao.pause(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-18',
          now: _now,
          resumesOn: '2026-11-25',
        );
        await db.habitDao.resume(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-20',
          now: _later,
        );
        expect(await db.habitDao.stateOn(habitId, '2026-11-19'),
            HabitState.paused);
        expect(await db.habitDao.stateOn(habitId, '2026-11-20'),
            HabitState.active);
        expect(await db.habitDao.stateOn(habitId, '2026-11-22'),
            HabitState.active);
      });

      test('a timed pause does not come back after archive and restore',
          () async {
        final habitId = await createHabit();
        await db.habitDao.pause(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-18',
          now: _now,
          resumesOn: '2026-11-25',
        );
        await db.habitDao.archive(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-20',
          now: _later,
        );
        await db.habitDao.restore(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-22',
          now: _later,
        );
        expect(await db.habitDao.stateOn(habitId, '2026-11-19'),
            HabitState.paused);
        expect(await db.habitDao.stateOn(habitId, '2026-11-21'),
            HabitState.archived);
        expect(await db.habitDao.stateOn(habitId, '2026-11-22'),
            HabitState.active);
      });

      test('refuses an archive dated before a pause that starts later',
          () async {
        final habitId = await createHabit();
        await db.habitDao.pause(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-25',
          now: _now,
        );
        await expectLater(
          db.habitDao.archive(
            habitId: habitId,
            userId: _userId,
            today: '2026-11-20',
            now: _later,
          ),
          throwsArgumentError,
        );
      });

      test('resume closes the pause at that day', () async {
        final habitId = await createHabit();
        await db.habitDao.pause(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-18',
          now: _now,
        );

        await db.habitDao.resume(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-20',
          now: _later,
        );

        expect(await db.habitDao.stateOn(habitId, '2026-11-19'),
            HabitState.paused);
        expect(await db.habitDao.stateOn(habitId, '2026-11-20'),
            HabitState.active);
      });

      test('archive closes an open pause and archives the Habit', () async {
        final habitId = await createHabit();
        await db.habitDao.pause(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-18',
          now: _now,
        );

        await db.habitDao.archive(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-20',
          now: _later,
        );

        expect(await db.habitDao.stateOn(habitId, '2026-11-19'),
            HabitState.paused);
        expect(await db.habitDao.stateOn(habitId, '2026-11-20'),
            HabitState.archived);
        expect(await db.habitDao.stateOn(habitId, '2026-11-25'),
            HabitState.archived);
      });

      test('restore closes the archive and the Habit is active again', () async {
        final habitId = await createHabit();
        await db.habitDao.archive(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-20',
          now: _now,
        );

        await db.habitDao.restore(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-25',
          now: _later,
        );

        expect(await db.habitDao.stateOn(habitId, '2026-11-24'),
            HabitState.archived);
        expect(await db.habitDao.stateOn(habitId, '2026-11-25'),
            HabitState.active);
      });

      test('refuses to resume a Habit that is not paused', () async {
        final habitId = await createHabit();

        await expectLater(
          db.habitDao.resume(
            habitId: habitId,
            userId: _userId,
            today: '2026-11-18',
            now: _now,
          ),
          throwsArgumentError,
        );
      });

      test('refuses to archive a Habit that is already archived', () async {
        final habitId = await createHabit();
        await db.habitDao.archive(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-18',
          now: _now,
        );

        await expectLater(
          db.habitDao.archive(
            habitId: habitId,
            userId: _userId,
            today: '2026-11-20',
            now: _later,
          ),
          throwsArgumentError,
        );
      });

      test('refuses to restore a Habit that is not archived', () async {
        final habitId = await createHabit();

        await expectLater(
          db.habitDao.restore(
            habitId: habitId,
            userId: _userId,
            today: '2026-11-18',
            now: _now,
          ),
          throwsArgumentError,
        );
      });

      test('authors no op — the habit tables are local', () async {
        final habitId = await createHabit();
        await db.habitDao.pause(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-18',
          now: _now,
        );
        await db.habitDao.resume(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-20',
          now: _later,
        );
        await db.habitDao.archive(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-21',
          now: _later,
        );
        await db.habitDao.restore(
          habitId: habitId,
          userId: _userId,
          today: '2026-11-22',
          now: _later,
        );
        expect(capture.recorded, isEmpty);
      });
    });

    group('Area and Labels', () {
      Future<String> createTag(String id, String name, String type) async {
        await db.into(db.tags).insert(TagsCompanion(
          id: Value(id),
          name: Value(name),
          type: Value(type),
          userId: const Value(_userId),
        ));
        return id;
      }

      /// The tag ids the Habit's junction rows hold, in row order.
      ///
      /// Read through the rows rather than through [HabitDao.tagsFor]: the
      /// read hides an orphan, so a row that outlived its tag would not show
      /// up there, and a test that claims "the first Area is gone" wants the
      /// row gone too.
      Future<List<String>> habitTagIds(String habitId) async {
        final rows = await (db.select(db.habitTags)
              ..where((ht) => ht.habitId.equals(habitId)))
            .get();
        return rows.map((row) => row.tagId).toList();
      }

      test('a second Area replaces the first', () async {
        final habitId = await createHabit();
        await createTag('area-one', 'Health', 'area');
        await createTag('area-two', 'Work', 'area');

        await db.habitDao.setArea(
            habitId: habitId, userId: _userId, areaTagId: 'area-one');
        await db.habitDao.setArea(
            habitId: habitId, userId: _userId, areaTagId: 'area-two');

        final tags = await db.habitDao.tagsFor(habitId);
        expect(tags, hasLength(1));
        expect(tags.single.id, 'area-two');
        expect(await habitTagIds(habitId), ['area-two'],
            reason: 'a Habit has one Area: the first one must be gone, not '
                'merely out of the read');
      });

      test('taking the Area away leaves the Habit with none', () async {
        final habitId = await createHabit();
        await createTag('area-one', 'Health', 'area');
        await db.habitDao.setArea(
            habitId: habitId, userId: _userId, areaTagId: 'area-one');

        await db.habitDao.setArea(
            habitId: habitId, userId: _userId, areaTagId: null);

        expect(await db.habitDao.tagsFor(habitId), isEmpty);
        expect(await habitTagIds(habitId), isEmpty);
      });

      test('refuses a tag that is not an Area', () async {
        final habitId = await createHabit();
        await createTag('label-one', 'Deep work', 'label');

        await expectLater(
          db.habitDao.setArea(
              habitId: habitId, userId: _userId, areaTagId: 'label-one'),
          throwsArgumentError,
        );
        expect(await db.habitDao.tagsFor(habitId), isEmpty);
      });

      test('a refused Project tag', () async {
        final habitId = await createHabit();
        await createTag('proj-one', 'Book', 'project');

        await expectLater(
          db.habitDao.assignLabel(
              habitId: habitId, userId: _userId, tagId: 'proj-one'),
          throwsArgumentError,
        );
        expect(await db.habitDao.tagsFor(habitId), isEmpty,
            reason: 'a refused tag must leave no row behind');
      });

      test('refuses an Area and a Person as a Label', () async {
        final habitId = await createHabit();
        await createTag('area-one', 'Health', 'area');
        await createTag('person-one', 'Alice', 'person');

        for (final tagId in ['area-one', 'person-one']) {
          await expectLater(
            db.habitDao.assignLabel(
                habitId: habitId, userId: _userId, tagId: tagId),
            throwsArgumentError,
          );
          await expectLater(
            db.habitDao.unassignLabel(
                habitId: habitId, userId: _userId, tagId: tagId),
            throwsArgumentError,
          );
        }
        expect(await db.habitDao.tagsFor(habitId), isEmpty);
      });

      test('gives the Habit its Labels and takes one away', () async {
        final habitId = await createHabit();
        await createTag('label-one', 'Deep work', 'label');
        await createTag('label-two', 'Focus', 'context');

        await db.habitDao.assignLabel(
            habitId: habitId, userId: _userId, tagId: 'label-one');
        await db.habitDao.assignLabel(
            habitId: habitId, userId: _userId, tagId: 'label-two');

        expect((await db.habitDao.tagsFor(habitId)).map((t) => t.id).toSet(),
            {'label-one', 'label-two'});

        await db.habitDao.unassignLabel(
            habitId: habitId, userId: _userId, tagId: 'label-one');

        final tags = await db.habitDao.tagsFor(habitId);
        expect(tags, hasLength(1));
        expect(tags.single.id, 'label-two');
      });

      test('assigning the same Label twice keeps one row', () async {
        final habitId = await createHabit();
        await createTag('label-one', 'Deep work', 'label');

        await db.habitDao.assignLabel(
            habitId: habitId, userId: _userId, tagId: 'label-one');
        await db.habitDao.assignLabel(
            habitId: habitId, userId: _userId, tagId: 'label-one');

        expect(await habitTagIds(habitId), ['label-one']);
      });

      test('an orphan habit_tags row is not returned', () async {
        final habitId = await createHabit();
        // A junction row whose tag is gone — the tag was deleted where the
        // Habit could not see it.
        await db.into(db.habitTags).insert(HabitTagsCompanion.insert(
              id: habitTagIdFor(habitId, 'gone-tag'),
              habitId: habitId,
              tagId: 'gone-tag',
              userId: _userId,
            ));

        expect(await db.habitDao.tagsFor(habitId), isEmpty);
      });

      test('authors no op — the habit tables are local', () async {
        final habitId = await createHabit();
        await createTag('area-one', 'Health', 'area');
        await createTag('label-one', 'Deep work', 'label');

        await db.habitDao.setArea(
            habitId: habitId, userId: _userId, areaTagId: 'area-one');
        await db.habitDao.assignLabel(
            habitId: habitId, userId: _userId, tagId: 'label-one');
        await db.habitDao.unassignLabel(
            habitId: habitId, userId: _userId, tagId: 'label-one');

        expect(capture.recorded, isEmpty);
      });
    });

    group('watchHabits', () {
      test('gives the Habits with their state on the day, oldest first',
          () async {
        final first = await createHabit(title: 'First');
        final second = await createHabit(title: 'Second', now: _later);
        await db.habitDao.pause(
          habitId: second,
          userId: _userId,
          today: '2026-11-18',
          now: _now,
        );

        final watched = await db.habitDao.watchHabits('2026-11-18').first;
        expect(watched.map((h) => h.habit.id), [first, second]);
        expect(watched.map((h) => h.state),
            [HabitState.active, HabitState.paused]);
      });

      test('filters by the archived state', () async {
        final first = await createHabit(title: 'First');
        final second = await createHabit(title: 'Second', now: _later);
        await db.habitDao.archive(
          habitId: second,
          userId: _userId,
          today: '2026-11-18',
          now: _now,
        );

        final archived =
            await db.habitDao.watchHabits('2026-11-18', archived: true).first;
        expect(archived.map((h) => h.habit.id), [second]);

        final live =
            await db.habitDao.watchHabits('2026-11-18', archived: false).first;
        expect(live.map((h) => h.habit.id), [first]);
      });
    });

    group("the Habit's Place", () {
      /// The area a pin is dropped at.
      final area = PlaceArea.create(
        latitudeDegrees: 52.3702,
        longitudeDegrees: 4.8952,
        radiusMeters: 150,
      )!;

      /// A named Place of the user's own.
      Future<String> namedPlace(String name) async {
        final id = await db.placeDao.createNamedPlace(
          name: name,
          latitudeDegrees: 52.3702,
          longitudeDegrees: 4.8952,
          userId: _userId,
          now: _now,
        );
        return id!;
      }

      /// The Place id the Habit row holds, read straight from the row.
      Future<String?> placeIdOf(String habitId) async {
        final row = await (db.select(db.habits)
              ..where((h) => h.id.equals(habitId)))
            .getSingle();
        return row.placeId;
      }

      test('a named Place is set, replaced and cleared', () async {
        final habitId = await createHabit();
        final first = await namedPlace('Hardware store');
        final second = await namedPlace('Bike shop');

        expect(await db.habitDao.setNamedPlace(habitId, first, now: _now),
            isTrue);
        expect(await placeIdOf(habitId), first);

        expect(await db.habitDao.setNamedPlace(habitId, second, now: _now),
            isTrue);
        expect(await placeIdOf(habitId), second);

        expect(await db.habitDao.setNamedPlace(habitId, null, now: _now),
            isTrue);
        expect(await placeIdOf(habitId), isNull);
      });

      test('the Place the Habit already carries is not written again',
          () async {
        final habitId = await createHabit();
        final placeId = await namedPlace('Hardware store');
        await db.habitDao.setNamedPlace(habitId, placeId, now: _now);

        expect(await db.habitDao.setNamedPlace(habitId, placeId, now: _now),
            isFalse);
      });

      test('the Habit row authors no op — the habit tables are local',
          () async {
        final habitId = await createHabit();
        final placeId = await namedPlace('Hardware store');
        capture.clear();

        await db.habitDao.setNamedPlace(habitId, placeId, now: _now);

        expect(capture.recorded, isEmpty);
      });

      test('a pin is a Place row of its own, with one op', () async {
        final habitId = await createHabit();
        capture.clear();

        final pinId = await db.habitDao.setPin(
          habitId,
          area,
          name: '  Corner  ',
          now: _now,
        );

        expect(pinId, isNotNull);
        final place =
            await (db.select(db.places)..where((p) => p.id.equals(pinId!)))
                .getSingle();
        expect(place.kind, pinPlaceKind);
        expect(place.name, 'Corner');
        expect(place.userId, _userId);
        expect(place.latitudeMicrodegrees, area.latitudeMicrodegrees);
        expect(place.radiusMeters, area.radiusMeters);
        expect(await placeIdOf(habitId), pinId);
        // The pin is a `places` row, so it syncs and the op says so. The Habit
        // row itself authors none.
        expect(capture.recorded, hasLength(1));
        expect(capture.recorded.single.collection, placesCollection);
        expect(capture.recorded.single.entityId, pinId);
      });

      test('replacing a pin deletes the old pin row and tombstones it',
          () async {
        final habitId = await createHabit();
        final first = await db.habitDao.setPin(habitId, area, now: _now);
        capture.clear();

        final second = await db.habitDao.setPin(
          habitId,
          PlaceArea.create(latitudeDegrees: 52.0, longitudeDegrees: 0.5)!,
          now: _now,
        );

        expect((await db.select(db.places).get()).map((p) => p.id), [second]);
        expect(await placeIdOf(habitId), second);
        final tombstoned = capture.recorded
            .where((op) => op.tombstone)
            .map((op) => '${op.collection}/${op.entityId}');
        expect(tombstoned, contains('places/$first'));
      });

      test('clearing the Place takes the pin it pointed at with it', () async {
        final habitId = await createHabit();
        await db.habitDao.setPin(habitId, area, now: _now);

        expect(await db.habitDao.setNamedPlace(habitId, null, now: _now),
            isTrue);

        expect(await db.select(db.places).get(), isEmpty);
        expect(await placeIdOf(habitId), isNull);
      });

      test('a named Place replaces a pin, and the named Place stays in the '
          'list', () async {
        final habitId = await createHabit();
        final placeId = await namedPlace('Hardware store');
        await db.habitDao.setPin(habitId, area, now: _now);

        expect(await db.habitDao.setNamedPlace(habitId, placeId, now: _now),
            isTrue);

        expect(await placeIdOf(habitId), placeId);
        // The pin went with the reference; the named Place is the user's own
        // and stays where it was.
        final places = await db.select(db.places).get();
        expect(places.map((p) => p.id), [placeId]);
      });

      test('a Place on a Habit that is not there writes nothing', () async {
        expect(
            await db.habitDao
                .setNamedPlace('no-such-habit', 'some-place', now: _now),
            isFalse);
        expect(await db.habitDao.setPin('no-such-habit', area, now: _now),
            isNull);

        expect(await db.select(db.places).get(), isEmpty);
        expect(capture.recorded, isEmpty);
      });

      test('a Place that does not exist is refused, and so is a pin', () async {
        final habitId = await createHabit();

        expect(
            await db.habitDao
                .setNamedPlace(habitId, 'no-such-place', now: _now),
            isFalse);
        expect(await placeIdOf(habitId), isNull);

        final pinId = await db.habitDao.setPin(habitId, area, now: _now);
        expect(await db.habitDao.setNamedPlace(habitId, pinId, now: _now),
            isFalse);
        expect(await placeIdOf(habitId), pinId,
            reason: 'a refused write leaves the Habit as it was');
      });

      group('watchHabitPlaces', () {
        test('gives the Place each Habit carries, keyed by Habit id', () async {
          final habitId = await createHabit();
          final placeId = await namedPlace('Hardware store');
          await db.habitDao.setNamedPlace(habitId, placeId, now: _now);

          final places = await db.habitDao.watchHabitPlaces().first;
          expect(places.keys, [habitId]);
          expect(places[habitId]!.id, placeId);
          expect(places[habitId]!.name, 'Hardware store');
          expect(places[habitId]!.isPin, isFalse);
          expect(places[habitId]!.area.latitudeMicrodegrees, 52370200);
          expect(places[habitId]!.area.radiusMeters, 150);
        });

        test('a Habit at no place is not in the map', () async {
          await createHabit();

          final places = await db.habitDao.watchHabitPlaces().first;
          expect(places, isEmpty);
        });

        test('re-emits when the Place is renamed', () async {
          final habitId = await createHabit();
          final placeId = await namedPlace('Hardware store');
          await db.habitDao.setNamedPlace(habitId, placeId, now: _now);

          final names = <String?>[];
          final firstSeen = Completer<void>();
          final renamed = Completer<void>();
          final subscription = db.habitDao.watchHabitPlaces().listen((places) {
            final name = places[habitId]?.name;
            names.add(name);
            if (!firstSeen.isCompleted) firstSeen.complete();
            if (name == 'Bike shop' && !renamed.isCompleted) renamed.complete();
          });
          addTearDown(subscription.cancel);

          await firstSeen.future.timeout(const Duration(seconds: 10));
          expect(names.first, 'Hardware store');

          await db.placeDao
              .updateNamedPlace(placeId: placeId, name: 'Bike shop');

          await renamed.future.timeout(const Duration(seconds: 10));
          expect(names.last, 'Bike shop');
        });

        test('omits a Habit whose Place is gone', () async {
          final habitId = await createHabit();
          final placeId = await namedPlace('Hardware store');
          await db.habitDao.setNamedPlace(habitId, placeId, now: _now);

          // The Place is deleted on another device and arrives as a
          // tombstone: the Habit's id now points at nothing.
          await db.customStatement("DELETE FROM places WHERE id = '$placeId'");

          final places = await db.habitDao.watchHabitPlaces().first;
          expect(places, isEmpty);
        });
      });
    });
  });
}
