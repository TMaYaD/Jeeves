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
import 'package:jeeves/providers/habit_check_ins_provider.dart';
import 'package:jeeves/providers/habit_stack_offer_provider.dart';
import '../test_helpers.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    configureSqliteForTests();
  });

  late GtdDatabase db;
  late ProviderContainer container;
  final now = DateTime(2026, 11, 18, 9, 30);

  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    db = GtdDatabase(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => now),
    ]);
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<String> createHabit(String title, int minute) {
    final created = DateTime(2026, 11, 10, 8, minute);
    return db.habitDao.createHabit(
      userId: container.read(currentUserIdProvider),
      title: title,
      today: habitDayKey(created),
      now: created.toUtc(),
      firstCommitment:
          const HabitCommitmentDraft(repeatKind: HabitRepeatKind.everyDay),
    );
  }

  Future<void> follow(String habitId, String anchorId) =>
      db.habitDao.setAnchor(
        habitId: habitId,
        userId: container.read(currentUserIdProvider),
        today: habitDayKey(now),
        now: now.toUtc(),
        kind: HabitAnchorKind.afterHabit,
        anchorHabitId: anchorId,
      );

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

  test('the offer follows the source Check-in and is withdrawn with it',
      () async {
    final stretch = await createHabit('Stretch', 0);
    final water = await createHabit('Water', 1);
    await follow(water, stretch);
    final offered = offeredHabitProvider;

    container.read(habitStackOfferProvider.notifier).checkedIn(stretch);
    expect((await settled(offered, (h) => h != null)), isNull,
        reason: 'the source is not done yet');

    final checkInId =
        await container.read(habitCheckInsProvider.notifier).checkIn(stretch);
    expect((await settled(offered, (h) => h != null))?.id, water);

    await container.read(habitCheckInsProvider.notifier).remove(checkInId);
    expect(await settled(offered, (h) => h == null), isNull);
  });

  test('"Not now" clears the offer', () async {
    final stretch = await createHabit('Stretch', 0);
    final water = await createHabit('Water', 1);
    await follow(water, stretch);
    container.read(habitStackOfferProvider.notifier).checkedIn(stretch);
    await container.read(habitCheckInsProvider.notifier).checkIn(stretch);
    expect((await settled(offeredHabitProvider, (h) => h != null))?.id, water);

    container.read(habitStackOfferProvider.notifier).dismiss();
    expect(container.read(offeredHabitProvider), isNull);
  });
}
