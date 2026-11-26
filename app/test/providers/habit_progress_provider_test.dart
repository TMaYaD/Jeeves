import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/daos/habit_dao.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/habit_commitment.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
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
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<String> createHabit(String title, HabitRepeatKind kind,
      {int? timesPerPeriod, DateTime? at}) {
    final created = at ?? now;
    return db.habitDao.createHabit(
      userId: _userId,
      title: title,
      today: habitDayKey(created),
      now: created.toUtc(),
      firstCommitment:
          HabitCommitmentDraft(repeatKind: kind, timesPerPeriod: timesPerPeriod),
    );
  }

  /// Keeps the streams alive and waits for a one-shot value that satisfies
  /// [ready] to show up.
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

  test('AC 8: for today holds due and unfinished Habits, never a paused one',
      () async {
    final daily = await createHabit('Stretch', HabitRepeatKind.everyDay,
        at: DateTime(2026, 11, 10, 8));
    final weekly = await createHabit('Run', HabitRepeatKind.timesPerWeek,
        timesPerPeriod: 2, at: DateTime(2026, 11, 10, 8, 1));
    final met = await createHabit('Swim', HabitRepeatKind.timesPerWeek,
        timesPerPeriod: 1, at: DateTime(2026, 11, 10, 8, 2));
    final paused = await createHabit('Read', HabitRepeatKind.everyDay,
        at: DateTime(2026, 11, 10, 8, 3));
    await db.habitDao.addCheckIn(
        habitId: met,
        userId: _userId,
        countsForDay: '2026-11-16',
        now: DateTime.utc(2026, 11, 16, 9));
    await db.habitDao.pause(
        habitId: paused,
        userId: _userId,
        today: '2026-11-18',
        now: DateTime.utc(2026, 11, 18, 8));

    final forToday = await settled(
        habitsForTodayProvider, (set) => set.contains(daily));

    expect(forToday, {daily, weekly});
    final chains = await settled(
        habitStackChainsProvider, (c) => c.isNotEmpty);
    expect(chains.expand((c) => c).map((h) => h.id).toSet(),
        {daily, weekly, met});
    final progress = await settled(
        habitProgressProvider(daily), (p) => p != null);
    expect(progress!.currentStreak, 0);
  });

  test('a Check-in updates the Habit progress', () async {
    final habitId = await createHabit('Stretch', HabitRepeatKind.everyDay);
    await settled(habitProgressProvider(habitId), (p) => p != null);

    await db.habitDao.addCheckIn(
        habitId: habitId,
        userId: _userId,
        countsForDay: '2026-11-18',
        now: now.toUtc());

    final progress = await settled(habitProgressProvider(habitId),
        (p) => p?.currentStreak == 1);
    expect(progress!.currentStreak, 1);
  });

  test('the day rollover at midnight recomputes for-today', () async {
    // A chosen-weekday Habit due on Thursdays only (2026-11-19).
    final habitId = await db.habitDao.createHabit(
      userId: _userId,
      title: 'Thursday thing',
      today: '2026-11-12',
      now: DateTime.utc(2026, 11, 12, 8),
      firstCommitment: const HabitCommitmentDraft(
        repeatKind: HabitRepeatKind.chosenWeekdays,
        chosenWeekdays: [DateTime.thursday],
      ),
    );
    now = DateTime(2026, 11, 18, 23, 59, 59);
    expect(container.read(habitTodayProvider), '2026-11-18');
    expect(await settled(habitsForTodayProvider, (_) => false),
        isNot(contains(habitId)));

    now = DateTime(2026, 11, 19, 0, 0, 1);
    container.invalidate(habitTodayProvider);

    expect(container.read(habitTodayProvider), '2026-11-19');
    final forToday = await settled(
        habitsForTodayProvider, (set) => set.contains(habitId));
    expect(forToday, contains(habitId));
  });

  testWidgets('habitTodayProvider re-checks the day when the app resumes',
      (tester) async {
    now = DateTime(2026, 11, 18, 22, 0);
    final resumed = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => now),
    ]);
    resumed.listen(habitTodayProvider, (_, _) {});
    expect(resumed.read(habitTodayProvider), '2026-11-18');

    now = DateTime(2026, 11, 19, 7, 0);
    expect(resumed.read(habitTodayProvider), '2026-11-18');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(resumed.read(habitTodayProvider), '2026-11-19');
    resumed.dispose();
  });

  test('habitTodayEntriesProvider lists today\'s Check-ins oldest first with '
      'the commitment in force', () async {
    final habit = await createHabit('Run', HabitRepeatKind.timesPerWeek,
        timesPerPeriod: 3, at: DateTime(2026, 11, 10, 8));
    Future<String> add(String day, DateTime at) => db.habitDao.addCheckIn(
        habitId: habit, userId: _userId, countsForDay: day, now: at.toUtc());
    final later = await add('2026-11-18', DateTime(2026, 11, 18, 9, 30));
    final earlier = await add('2026-11-18', DateTime(2026, 11, 18, 7, 5));
    await add('2026-11-17', DateTime(2026, 11, 17, 8));

    final entries = await settled(habitTodayEntriesProvider(habit),
        (e) => e != null && e.checkIns.length == 2);

    expect([for (final c in entries!.checkIns) c.id], [earlier, later]);
    expect(entries.commitment?.timesPerPeriod, 3);
  });

  test('habitTodayEntriesProvider is null for an unknown Habit', () async {
    await createHabit('Run', HabitRepeatKind.everyDay);
    await settled(habitHistoriesProvider, (h) => h.hasValue);
    expect(container.read(habitTodayEntriesProvider('nope')), isNull);
  });
}
