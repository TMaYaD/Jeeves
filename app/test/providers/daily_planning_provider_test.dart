import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/daily_planning_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import '../test_helpers.dart';

ProviderContainer _container(GtdDatabase db) => ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );

void main() {
  setUpAll(configureSqliteForTests);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('DailyPlanningNotifier', () {
    late GtdDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = GtdDatabase.forTesting(NativeDatabase.memory());
      container = _container(db);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
      planningCompletionNotifier.value = false;
    });

    test('startDay preserves energyLevel and availableMinutes', () async {
      final notifier = container.read(dailyPlanningProvider.notifier);

      notifier.setEnergyLevel('medium');
      notifier.setAvailableTime(300); // 5 hours

      await notifier.startDay();

      final stateAfterStart = container.read(dailyPlanningProvider);
      expect(stateAfterStart.energyLevel, 'medium',
          reason: 'startDay should not clear energy level');
      expect(stateAfterStart.availableMinutes, 300,
          reason: 'startDay should not clear available minutes');
      expect(stateAfterStart.availableTimeSet, isTrue,
          reason: 'startDay should not clear availableTimeSet flag');
    });

    test('reEnterPlanning restores energy and time after startDay', () async {
      final notifier = container.read(dailyPlanningProvider.notifier);

      notifier.setEnergyLevel('high');
      notifier.setAvailableTime(360); // 6 hours

      await notifier.startDay();
      await notifier.reEnterPlanning();

      final state = container.read(dailyPlanningProvider);
      expect(state.energyLevel, 'high',
          reason: 'reEnterPlanning should restore energy from before startDay');
      expect(state.availableMinutes, 360,
          reason: 'reEnterPlanning should restore available minutes');
      expect(state.availableTimeSet, isTrue,
          reason: 'reEnterPlanning should restore availableTimeSet flag');
      expect(state.currentStep, 0,
          reason: 'reEnterPlanning should reset to step 0');
    });

    test('startDay resets step and inbox counters', () async {
      final notifier = container.read(dailyPlanningProvider.notifier);

      notifier.setInitialInboxCount(5);
      notifier.advanceStep();
      notifier.advanceStep();

      await notifier.startDay();

      final state = container.read(dailyPlanningProvider);
      expect(state.currentStep, 0);
      expect(state.initialInboxCount, isNull);
      expect(state.inboxClarifiedCount, 0);
      expect(state.inboxSkippedCount, 0);
    });
  });
}
