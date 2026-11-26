import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/daos/habit_dao.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/habit_commitment.dart';
import 'package:jeeves/providers/auth_provider.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/evening_shutdown_provider.dart';
import 'package:jeeves/providers/habit_check_ins_provider.dart';
import 'package:jeeves/providers/habit_progress_provider.dart';
import 'package:jeeves/providers/shutdown_habits_provider.dart';
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
    // 00:20 on the 19th: the user is still closing the 18th.
    now = DateTime(2026, 11, 19, 0, 20);
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

  Future<void> openSessionStartedAt(DateTime startedAt) async {
    await db.into(db.todos).insert(TodosCompanion(
          id: const Value('t1'),
          title: const Value('Write'),
          userId: const Value(_userId),
          createdAt: Value(startedAt),
          updatedAt: Value(startedAt),
        ));
    await db.focusSessionDao
        .openSession(userId: _userId, taskIds: ['t1'], now: startedAt);
  }

  Future<void> finishWriteTask() => (db.update(db.todos)
        ..where((t) => t.id.equals('t1')))
      .write(TodosCompanion(doneAt: Value(DateTime.utc(2026, 11, 18, 22).toIso8601String())));

  const everyDay = HabitCommitmentDraft(repeatKind: HabitRepeatKind.everyDay);

  test('a session started 21:00 yesterday closes yesterday after midnight',
      () async {
    await openSessionStartedAt(DateTime(2026, 11, 18, 21));

    final day = await settled(shutdownClosingDayProvider, (v) => v.hasValue);

    expect(day.value, '2026-11-18');
  });

  test('with no open session the closing day is today', () async {
    final day = await settled(shutdownClosingDayProvider, (v) => v.hasValue);

    expect(day.value, '2026-11-19');
  });

  test('habitsForDayProvider(today) equals habitsForTodayProvider', () async {
    await createHabit('Stretch', everyDay, at: DateTime(2026, 11, 10, 8));
    final forToday =
        await settled(habitsForTodayProvider, (set) => set.isNotEmpty);

    final forDay = await settled(
        habitsForDayProvider('2026-11-19'), (set) => set.isNotEmpty);

    expect(forDay, forToday);
  });

  test(
      'the open list for yesterday leaves out a done and a paused Habit, '
      'keeps a measurable one below target, in stack order', () async {
    final stretch =
        await createHabit('Stretch', everyDay, at: DateTime(2026, 11, 10, 8));
    final water = await createHabit(
        'Water',
        const HabitCommitmentDraft(
          repeatKind: HabitRepeatKind.everyDay,
          unitLabel: 'glasses',
          dailyTargetAmount: 8,
        ),
        at: DateTime(2026, 11, 10, 8, 1));
    final read = await createHabit('Read', everyDay,
        at: DateTime(2026, 11, 10, 8, 2));
    final paused = await createHabit('Journal', everyDay,
        at: DateTime(2026, 11, 10, 8, 3));
    final doneYesterday = await createHabit('Walk', everyDay,
        at: DateTime(2026, 11, 10, 8, 4));
    await db.habitDao.pause(
        habitId: paused,
        userId: _userId,
        today: '2026-11-17',
        now: DateTime.utc(2026, 11, 17, 8));
    final actions = container.read(habitCheckInsProvider.notifier);
    await actions.checkIn(doneYesterday, countsForDay: '2026-11-18');
    await actions.checkIn(water, amount: 5, countsForDay: '2026-11-18');
    await openSessionStartedAt(DateTime(2026, 11, 18, 21));

    final open = await settled(
        shutdownOpenHabitsProvider, (list) => list.length == 3);

    expect([for (final o in open) o.habit.id], [stretch, water, read]);
    expect(open[1].progress.todayTotalAmount, 5);
    expect(open[1].progress.targetAmount, 8);
  });

  test('a Check-in counted for today does not close yesterday\'s Habit',
      () async {
    final stretch =
        await createHabit('Stretch', everyDay, at: DateTime(2026, 11, 10, 8));
    await container
        .read(habitCheckInsProvider.notifier)
        .checkIn(stretch, countsForDay: '2026-11-19');
    await openSessionStartedAt(DateTime(2026, 11, 18, 21));

    final open = await settled(
        shutdownOpenHabitsProvider, (list) => list.isNotEmpty);

    expect([for (final o in open) o.habit.id], [stretch]);
  });

  test('a weekly Habit created after the closing day is not open on it',
      () async {
    final weekly = await createHabit(
        'Run',
        const HabitCommitmentDraft(
            repeatKind: HabitRepeatKind.timesPerWeek, timesPerPeriod: 3),
        at: DateTime(2026, 11, 19, 0, 10));
    await openSessionStartedAt(DateTime(2026, 11, 18, 21));
    await settled(shutdownClosingDayProvider, (v) => v.hasValue);

    final open = await settled(
        shutdownOpenHabitsProvider, (list) => list.isNotEmpty);

    expect([for (final o in open) o.habit.id], isNot(contains(weekly)));
  });

  test('closing after habits only closes nothing when the session changed',
      () async {
    await openSessionStartedAt(DateTime(2026, 11, 18, 21));
    await finishWriteTask();
    final notifier = container.read(eveningShutdownProvider.notifier);

    expect(await notifier.closeAfterHabitsOnly('2026-11-17'), isFalse);
    expect(await db.focusSessionDao.getActiveSession(), isNotNull);

    expect(await notifier.closeAfterHabitsOnly('2026-11-18'), isTrue);
    expect(await db.focusSessionDao.getActiveSession(), isNull);
  });

  test('a different session starts with its Habits step owed again',
      () async {
    await openSessionStartedAt(DateTime(2026, 11, 18, 21));
    await finishWriteTask();
    final notifier = container.read(eveningShutdownProvider.notifier);
    await notifier.markStarted();
    notifier.finishHabitsStep();
    expect(container.read(eveningShutdownProvider).habitsStepDone, isTrue);

    await notifier.markStarted();
    expect(container.read(eveningShutdownProvider).habitsStepDone, isTrue);

    await db.focusSessionDao.closeSessionIfNothingToDispose(
        sessionId: (await db.focusSessionDao.getActiveSession())!.id);
    await db.focusSessionDao.openSession(
        userId: _userId, taskIds: ['t1'], now: DateTime(2026, 11, 19, 8));
    await notifier.markStarted();

    expect(container.read(eveningShutdownProvider).habitsStepDone, isFalse);
  });
}
