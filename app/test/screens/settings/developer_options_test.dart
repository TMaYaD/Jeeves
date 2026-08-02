import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/database_provider.dart';
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

Future<void> _pumpSettings(WidgetTester tester) async {
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

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapJeeves(WidgetTester tester, int times) async {
  await tester.scrollUntilVisible(
    find.byKey(const Key('about_jeeves_name')),
    200,
  );
  for (var i = 0; i < times; i++) {
    await tester.tap(find.byKey(const Key('about_jeeves_name')));
  }
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(configureSqliteForTests);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Settings — hidden developer options', () {
    const exportTile = Key('developer_options_export_tile');

    testWidgets('are hidden until the Jeeves name is tapped', (tester) async {
      await _pumpSettings(tester);
      expect(find.byKey(exportTile), findsNothing);
      expect(find.text('DEVELOPER OPTIONS'), findsNothing);
    });

    testWidgets('stay hidden below seven taps', (tester) async {
      await _pumpSettings(tester);
      await _tapJeeves(tester, 6);
      expect(find.byKey(exportTile), findsNothing);
    });

    testWidgets('unlock on the seventh tap, revealing Export data',
        (tester) async {
      await _pumpSettings(tester);
      await _tapJeeves(tester, 7);

      await tester.scrollUntilVisible(find.byKey(exportTile), 200);
      expect(find.byKey(exportTile), findsOneWidget);
      expect(find.text('DEVELOPER OPTIONS'), findsOneWidget);
    });
  });
}
