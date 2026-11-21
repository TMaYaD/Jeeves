import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/daos/habit_dao.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/habit_commitment.dart';
import 'package:jeeves/models/habit_progress.dart';
import 'package:jeeves/providers/auth_provider.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/habit_check_ins_provider.dart';
import 'package:jeeves/providers/habit_progress_provider.dart';
import 'package:jeeves/sync/domain_op_capture.dart';
import '../test_helpers.dart';

const _userId = 'test-user';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    configureSqliteForTests();
  });

  late GtdDatabase db;
  late DateTime now;
  late ProviderContainer container;

  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    db = GtdDatabase(NativeDatabase.memory(),
        opCapture: RecordingDomainOpCapture());
    now = DateTime(2026, 11, 18, 9, 30);
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => now),
    ]);
    container.read(currentUserIdProvider.notifier).setUserId(_userId);
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<String> createHabit(String title, HabitCommitmentDraft commitment,
      {required DateTime at}) {
    return db.habitDao.createHabit(
      userId: _userId,
      title: title,
      today: habitDayKey(at),
      now: at.toUtc(),
      firstCommitment: commitment,
    );
  }

  /// Keeps the streams alive and waits for a value that satisfies [ready].
  Future<T> settled<T>(
      ProviderListenable<T> provider, bool Function(T) ready) async {
    container.listen(provider, (_, _) {}, fireImmediately: true);
    for (var i = 0; i < 200; i++) {
      final value = container.read(provider);
      if (ready(value)) return value;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return container.read(provider);
  }

  Future<HabitProgress?> progressOf(
          String habitId, bool Function(HabitProgress) ready) =>
      settled(habitProgressProvider(habitId),
          (progress) => progress != null && ready(progress));

  HabitCheckInActions actions() => container.read(habitCheckInsProvider.notifier);

  test('AC 7: a Check-in added and removed 10 days back recomputes the streak',
      () async {
    final habit = await createHabit(
        'Stretch', const HabitCommitmentDraft(repeatKind: HabitRepeatKind.everyDay),
        at: DateTime(2026, 11, 1, 8));
    for (var day = 1; day <= 17; day++) {
      if (day == 8) continue;
      await actions().checkIn(habit,
          countsForDay: '2026-11-${day.toString().padLeft(2, '0')}');
    }

    final gap = await progressOf(habit, (p) => p.currentStreak == 9);
    expect(gap!.currentStreak, 9);
    expect(gap.bestStreak, 9);
    expect(gap.rates[1].value, closeTo(16 / 17, 1e-9));

    final added = await actions().checkIn(habit, countsForDay: '2026-11-08');
    final filled = await progressOf(habit, (p) => p.currentStreak == 17);
    expect(filled!.currentStreak, 17);
    expect(filled.rates[1].value, 1.0);

    await actions().remove(added);
    final reopened = await progressOf(habit, (p) => p.currentStreak == 9);
    expect(reopened!.currentStreak, 9);
    expect(reopened.rates[1].value, closeTo(16 / 17, 1e-9));
  });

  test('AC 7: changing the amount of a Check-in 10 days back recomputes',
      () async {
    final habit = await createHabit(
        'Water',
        const HabitCommitmentDraft(
          repeatKind: HabitRepeatKind.everyDay,
          unitLabel: 'glasses',
          dailyTargetAmount: 8,
        ),
        at: DateTime(2026, 11, 1, 8));
    for (var day = 1; day <= 17; day++) {
      if (day == 8) continue;
      await actions().checkIn(habit,
          amount: 8,
          countsForDay: '2026-11-${day.toString().padLeft(2, '0')}');
    }
    final short = await actions()
        .checkIn(habit, amount: 3, countsForDay: '2026-11-08');
    final missed = await progressOf(habit, (p) => p.currentStreak == 9);
    expect(missed!.currentStreak, 9);

    await actions().change(short, 8);

    final met = await progressOf(habit, (p) => p.currentStreak == 17);
    expect(met!.currentStreak, 17);
    expect(met.rates[1].value, 1.0);
  });

  test('AC 3: at 00:20 a Check-in for the closing day counts for that day',
      () async {
    final habit = await createHabit(
        'Journal', const HabitCommitmentDraft(repeatKind: HabitRepeatKind.everyDay),
        at: DateTime(2026, 11, 10, 8));
    now = DateTime(2026, 11, 19, 0, 20);

    final day = habitCheckInDay(now: now, closingDay: '2026-11-18');
    await actions().checkIn(habit, countsForDay: day);

    final rows = await db.habitDao.checkInsFor(habit, '2026-11-01', '2026-11-30');
    expect([for (final row in rows) row.countsForDay], ['2026-11-18']);
    final progress = await progressOf(habit, (p) => p.currentStreak == 1);
    expect(progress!.currentStreak, 1);
    expect(progress.todayState, HabitTodayState.notYet);
    expect(habitCheckInDay(now: now), '2026-11-19');
  });

  test('AC 2: three Check-ins on one day count three toward 3 a week',
      () async {
    final habit = await createHabit(
        'Run',
        const HabitCommitmentDraft(
            repeatKind: HabitRepeatKind.timesPerWeek, timesPerPeriod: 3),
        at: DateTime(2026, 11, 10, 8));

    await actions().checkIn(habit, countsForDay: '2026-11-17');
    await actions().checkIn(habit, countsForDay: '2026-11-17');
    final two = await progressOf(habit, (p) => p.periodCount == 2);
    expect(two!.periodCount, 2);
    expect(two.todayState, HabitTodayState.notYet);

    await actions().checkIn(habit, countsForDay: '2026-11-17');
    final three = await progressOf(habit, (p) => p.periodCount == 3);
    expect(three!.periodCount, 3);
    expect(three.periodTarget, 3);
  });

  test('checkIn counts for today by default', () async {
    final habit = await createHabit(
        'Stretch', const HabitCommitmentDraft(repeatKind: HabitRepeatKind.everyDay),
        at: DateTime(2026, 11, 10, 8));

    await actions().checkIn(habit);

    final rows = await db.habitDao.checkInsFor(habit, '2026-11-01', '2026-11-30');
    expect([for (final row in rows) row.countsForDay], ['2026-11-18']);
  });

  test('undo removes exactly the returned Check-in', () async {
    final habit = await createHabit(
        'Run',
        const HabitCommitmentDraft(
            repeatKind: HabitRepeatKind.timesPerWeek, timesPerPeriod: 3),
        at: DateTime(2026, 11, 10, 8));
    final first = await actions().checkIn(habit);
    final second = await actions().checkIn(habit);

    await actions().undo(first);

    final rows = await db.habitDao.checkInsFor(habit, '2026-11-01', '2026-11-30');
    expect([for (final row in rows) row.id], [second]);
  });

  test('a Check-in counts for the clock day even when habitTodayProvider is '
      'stale after the app wakes past midnight', () async {
    final habit = await createHabit('Stretch',
        const HabitCommitmentDraft(repeatKind: HabitRepeatKind.everyDay),
        at: DateTime(2026, 11, 17, 8));
    now = DateTime(2026, 11, 18, 22, 0);
    expect(container.read(habitTodayProvider), '2026-11-18');

    // The device slept: the clock moved on, the cached provider did not.
    now = DateTime(2026, 11, 19, 7, 0);
    expect(container.read(habitTodayProvider), '2026-11-18');

    final id = await actions().checkIn(habit);
    final rows = await db.habitDao.checkInsFor(habit, '2026-11-01', '2026-11-30');
    expect(rows.singleWhere((row) => row.id == id).countsForDay, '2026-11-19');
  });

  test('removeLatestOfToday removes only the later of today\'s Check-ins',
      () async {
    final habit = await createHabit(
        'Run',
        const HabitCommitmentDraft(
            repeatKind: HabitRepeatKind.timesPerWeek, timesPerPeriod: 3),
        at: DateTime(2026, 11, 10, 8));
    final yesterday = await actions().checkIn(habit, countsForDay: '2026-11-17');
    now = DateTime(2026, 11, 18, 9, 0);
    final morning = await actions().checkIn(habit);
    now = DateTime(2026, 11, 18, 9, 30);
    final later = await actions().checkIn(habit);

    final removed = await actions().removeLatestOfToday(habit);

    expect(removed, later);
    final rows = await db.habitDao.checkInsFor(habit, '2026-11-01', '2026-11-30');
    expect({for (final row in rows) row.id}, {yesterday, morning});
  });

  test('removeLatestOfToday changes nothing when there is none today',
      () async {
    final habit = await createHabit(
        'Run', const HabitCommitmentDraft(repeatKind: HabitRepeatKind.everyDay),
        at: DateTime(2026, 11, 10, 8));
    final yesterday = await actions().checkIn(habit, countsForDay: '2026-11-17');

    expect(await actions().removeLatestOfToday(habit), isNull);

    final rows = await db.habitDao.checkInsFor(habit, '2026-11-01', '2026-11-30');
    expect([for (final row in rows) row.id], [yesterday]);
  });
}
