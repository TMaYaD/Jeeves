import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_settings_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/screens/settings/settings_screen.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers.dart';

class _StubNotificationService extends NotificationService {
  _StubNotificationService() : super.forTesting();

  @override
  Future<void> scheduleRitualReminder(RitualId ritual, TimeOfDay time) async {}

  @override
  Future<void> cancelRitualReminder(RitualId ritual) async {}

  @override
  Future<void> cancelRecurringRitualReminder(RitualId ritual) async {}

  @override
  Future<void> snoozeRitualReminder(RitualId ritual, int minutes) async {}

  @override
  Future<void> skipTodayRitualReminder(RitualId ritual) async {}

  @override
  Future<void> cancelReminder(int id) async {}

  @override
  Future<void> cancelAll() async {}
}

/// Pumps the real Settings screen so the default-time-estimate tile is
/// exercised in the widget tree it actually ships in. [initialEstimate] seeds
/// the persisted preference so a test can start from a non-default value.
Future<ProviderContainer> _pumpSettings(
  WidgetTester tester, {
  int? initialEstimate,
}) async {
  final db = GtdDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      notificationServiceProvider.overrideWithValue(_StubNotificationService()),
    ],
  );
  addTearDown(container.dispose);
  await container.read(syncedPreferencesProvider.future);
  if (initialEstimate != null) {
    await container
        .read(focusSessionPlanningSettingsProvider.notifier)
        .setDefaultTimeEstimate(initialEstimate);
  }

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  setUpAll(configureSqliteForTests);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Settings — default time estimate', () {
    testWidgets('renders the tile with the 10 min default', (tester) async {
      await _pumpSettings(tester);

      await tester.scrollUntilVisible(
        find.byKey(const Key('planning_default_estimate_tile')),
        200,
      );

      expect(find.text('Default time estimate'), findsOneWidget);
      expect(find.text('10 min'), findsOneWidget);
    });

    testWidgets('picking a value persists via the notifier', (tester) async {
      final container = await _pumpSettings(tester);

      await tester.scrollUntilVisible(
        find.byKey(const Key('planning_default_estimate_tile')),
        200,
      );
      await tester
          .ensureVisible(find.byKey(const Key('planning_default_estimate_tile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('planning_default_estimate_tile')));
      await tester.pumpAndSettle();

      await tester
          .tap(find.byKey(const Key('planning_default_estimate_option_20')));
      await tester.pumpAndSettle();

      expect(
        container
            .read(focusSessionPlanningSettingsProvider)
            .defaultTimeEstimate,
        equals(20),
      );
      expect(
        container.read(syncedPreferencesProvider).asData!.value
            .get<int>('focus_session_planning_settings_default_time_estimate'),
        equals(20),
      );
    });

    testWidgets('dismissing the picker leaves the value untouched',
        (tester) async {
      final container = await _pumpSettings(tester, initialEstimate: 30);

      await tester.scrollUntilVisible(
        find.byKey(const Key('planning_default_estimate_tile')),
        200,
      );
      await tester
          .ensureVisible(find.byKey(const Key('planning_default_estimate_tile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('planning_default_estimate_tile')));
      await tester.pumpAndSettle();

      // Tap the barrier to dismiss without choosing.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(
        container
            .read(focusSessionPlanningSettingsProvider)
            .defaultTimeEstimate,
        equals(30),
      );
    });
  });
}
