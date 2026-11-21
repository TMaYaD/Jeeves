import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/daos/habit_dao.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/habit_commitment.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/habit_actions_provider.dart';

import '../test_helpers.dart';

void main() {
  setUpAll(configureSqliteForTests);

  test('saving one field leaves a field changed since an editor opened', () async {
    final db = GtdDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    final id = await db.habitDao.createHabit(
      userId: 'local',
      title: 'Read',
      today: habitDayKey(DateTime.now()),
      now: DateTime.now(),
      firstCommitment: defaultNewHabitCommitment,
    );
    final actions = container.read(habitActionsProvider);

    await actions.setTitle(id, 'Read daily');
    await actions.setNotes(id, 'Ten pages');
    // An editor opened before the title and notes were saved now saves only
    // the estimate and the energy level.
    await actions.setEstimate(id, 15);
    await actions.setEnergy(id, 'low');

    final habit = (await db.habitDao.habitById(id))!;
    expect(habit.title, 'Read daily');
    expect(habit.notes, 'Ten pages');
    expect(habit.timeEstimateMinutes, 15);
    expect(habit.energyLevel, 'low');
  });
}
