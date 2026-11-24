import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/daos/habit_dao.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/habit_commitment.dart';
import 'package:jeeves/providers/auth_provider.dart' show currentUserIdProvider;
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_provider.dart';
import 'package:jeeves/providers/habit_focus_provider.dart';
import 'package:jeeves/providers/sprint_timer_provider.dart' show SprintPhase;

import '../test_helpers.dart';

// currentUserIdProvider defaults to 'local'.
const _userId = 'local';

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late DateTime now;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    db = GtdDatabase(NativeDatabase.memory());
    now = DateTime(2026, 11, 18, 9, 0);
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => now),
    ]);
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<String> createHabit(String title, {int estimate = 30}) async {
    final id = await db.habitDao.createHabit(
      userId: _userId,
      title: title,
      today: habitDayKey(now),
      now: now.toUtc(),
      firstCommitment:
          const HabitCommitmentDraft(repeatKind: HabitRepeatKind.everyDay),
    );
    await db.habitDao.updateHabitDetails(
      habitId: id,
      userId: _userId,
      title: title,
      notes: null,
      energyLevel: null,
      timeEstimateMinutes: estimate,
      now: now.toUtc(),
    );
    return id;
  }

  Future<String> createOutcome() async {
    await db.into(db.todos).insert(TodosCompanion(
          title: const Value('Write report'),
          userId: const Value(_userId),
          createdAt: Value(now),
        ));
    return (await db.select(db.todos).get()).last.id;
  }

  test('start, break, sprint gives sprint 2; stop closes everything', () async {
    final habit = await createHabit('Meditate');
    final notifier = container.read(habitFocusProvider.notifier);

    await notifier.start(habit);
    expect(container.read(habitFocusProvider).phase, SprintPhase.focus);
    expect(container.read(habitFocusProvider).sprintNumber, 1);
    expect(container.read(habitFocusProvider).activeTaskTitle, 'Meditate');

    now = now.add(const Duration(minutes: 5));
    await notifier.startBreak();
    expect(container.read(habitFocusProvider).phase, SprintPhase.break_);

    now = now.add(const Duration(minutes: 1));
    await notifier.startSprint();
    expect(container.read(habitFocusProvider).phase, SprintPhase.focus);
    expect(container.read(habitFocusProvider).sprintNumber, 2);

    await notifier.stop();
    expect(container.read(habitFocusProvider).isActive, isFalse);
    expect(await db.select(db.habitTimeLogs).get(),
        everyElement(isA<HabitTimeLog>().having((l) => l.endedAt, 'ended', isNotNull)));
    expect((await db.select(db.habitSprints).get()).where((s) => s.endedAt == null),
        isEmpty);
    expect(await db.select(db.timeLogs).get(), isEmpty);
    expect(await db.select(db.sprints).get(), isEmpty);
  });

  test('starting a Habit while an Outcome is engaged closes its TimeLog',
      () async {
    final outcome = await createOutcome();
    final habit = await createHabit('Meditate');
    await container.read(focusModeProvider.notifier).startFocus(outcome);
    expect((await db.select(db.timeLogs).get()).single.endedAt, isNull);

    await container.read(habitFocusProvider.notifier).start(habit);

    expect((await db.select(db.timeLogs).get()).single.endedAt, isNotNull);
    expect(container.read(focusModeProvider).activeTodoId, isNull);
    expect(container.read(habitFocusProvider).isActive, isTrue);
  });

  test('a change of signed-in account drops the previous account\'s Focus',
      () async {
    final habit = await createHabit('Meditate');
    await container.read(habitFocusProvider.notifier).start(habit);
    expect(container.read(habitFocusProvider).isActive, isTrue);

    container.read(currentUserIdProvider.notifier).setUserId('someone-else');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(container.read(habitFocusProvider).isActive, isFalse);
    expect(container.read(habitFocusProvider).activeTaskTitle, isNull);
  });

  test('starting an Outcome while a Habit is in Focus closes the habit log',
      () async {
    final outcome = await createOutcome();
    final habit = await createHabit('Meditate');
    await container.read(habitFocusProvider.notifier).start(habit);
    expect((await db.select(db.habitTimeLogs).get()).single.endedAt, isNull);

    await container.read(focusModeProvider.notifier).startFocus(outcome);

    expect((await db.select(db.habitTimeLogs).get()).single.endedAt,
        isNotNull);
    expect((await db.select(db.habitSprints).get()).single.endedAt, isNotNull);
    expect((await db.select(db.timeLogs).get()).single.endedAt, isNull);
  });

  test('an open log from before a restart is adopted, not duplicated',
      () async {
    final habit = await createHabit('Meditate');
    await db.habitFocusDao.openHabitFocus(
        habitId: habit, userId: _userId, plannedSprintMinutes: 20, now: now);
    now = now.add(const Duration(minutes: 3));

    await container.read(habitFocusProvider.notifier).start(habit);

    expect(await db.select(db.habitTimeLogs).get(), hasLength(1));
    expect(container.read(habitFocusProvider).phase, SprintPhase.focus);
  });
}
