/// The Habit detail's reads and the anchor rule the Anchor sheet relies on
/// (#402), against a real in-memory store.
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/daos/habit_dao.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/habit_commitment.dart';
import 'package:jeeves/screens/habits/habit_anchor_candidates.dart';
import '../test_helpers.dart';

const _userId = 'test-user';
final _now = DateTime.utc(2026, 11, 18, 9, 30);
const _today = '2026-11-18';

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    db = GtdDatabase(NativeDatabase.memory());
  });
  tearDown(() async => db.close());

  Future<String> create(String title) => db.habitDao.createHabit(
    userId: _userId,
    title: title,
    today: _today,
    now: _now,
    firstCommitment: defaultNewHabitCommitment,
  );

  test(
    'every candidate the Anchor sheet offers is accepted by setAnchor',
    () async {
      final ids = [
        for (final t in ['A', 'B', 'C', 'D']) await create(t),
      ];
      Future<void> anchor(String id, HabitAnchorKind kind, String target) =>
          db.habitDao.setAnchor(
            habitId: id,
            userId: _userId,
            today: _today,
            now: _now,
            kind: kind,
            anchorHabitId: target,
          );
      await anchor(ids[1], HabitAnchorKind.afterHabit, ids[0]);
      await anchor(ids[2], HabitAnchorKind.beforeHabit, ids[1]);

      final all = await db.select(db.habits).get();
      final activeIds = {for (final h in all) h.id};
      for (final habit in all) {
        final candidates = anchorCandidates(habit, all, activeIds);
        for (final candidate in candidates) {
          for (final kind in [
            HabitAnchorKind.afterHabit,
            HabitAnchorKind.beforeHabit,
          ]) {
            await anchor(habit.id, kind, candidate.id);
            // Put the original anchor back so each pair is judged alone.
            await db.habitDao.setAnchor(
              habitId: habit.id,
              userId: _userId,
              today: _today,
              now: _now,
              kind:
                  HabitAnchorKind.tryParse(habit.anchorKind) ??
                  HabitAnchorKind.none,
              anchorHabitId: habit.anchorHabitId,
            );
          }
        }
      }
    },
  );

  test(
    'watchHabit, watchCommitmentsFor and watchTagsFor emit after a write',
    () async {
      final id = await create('Read');
      await db.tagDao.upsertTag(
        TagsCompanion(
          id: const Value('area-home'),
          name: const Value('Home'),
          type: const Value('area'),
          userId: const Value(_userId),
        ),
      );

      final habits = <String?>[];
      final commitmentCounts = <int>[];
      final tagIds = <List<String>>[];
      final subs = [
        db.habitDao.watchHabit(id).listen((h) => habits.add(h?.title)),
        db.habitDao
            .watchCommitmentsFor(id)
            .listen((c) => commitmentCounts.add(c.length)),
        db.habitDao
            .watchTagsFor(id)
            .listen((t) => tagIds.add([for (final x in t) x.id])),
      ];
      await pumpEventQueue();

      await db.habitDao.updateHabitDetails(
        habitId: id,
        userId: _userId,
        title: 'Read more',
        notes: null,
        energyLevel: null,
        timeEstimateMinutes: null,
        now: _now.add(const Duration(minutes: 1)),
      );
      await db.habitDao.setCommitment(
        habitId: id,
        userId: _userId,
        today: _today,
        now: _now.add(const Duration(minutes: 2)),
        commitment: const HabitCommitmentDraft(
          repeatKind: HabitRepeatKind.timesPerWeek,
          timesPerPeriod: 3,
        ),
      );
      await db.habitDao.setArea(
        habitId: id,
        userId: _userId,
        areaTagId: 'area-home',
      );
      await pumpEventQueue();

      expect(habits.last, 'Read more');
      expect(commitmentCounts.last, 2);
      expect(tagIds.last, ['area-home']);
      for (final s in subs) {
        await s.cancel();
      }
    },
  );
}
