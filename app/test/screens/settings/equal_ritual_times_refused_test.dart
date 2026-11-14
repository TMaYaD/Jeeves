import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/nudge_clock_provider.dart';
import 'package:jeeves/providers/shutdown_settings_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/screens/settings/settings_screen.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers.dart';

const _refusal = "Daily Planning and Evening Shutdown can't be at the same time.";

void main() {
  setUpAll(configureSqliteForTests);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Settings with Daily Planning at its 08:00 default and Evening Shutdown at
  /// [shutdownTime]; then taps [tileKey] and accepts the picker's time as is.
  Future<void> acceptPickerOn(
    WidgetTester tester,
    Key tileKey, {
    required TimeOfDay shutdownTime,
  }) async {
    final db = GtdDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(overrides: [
      nudgeBoundaryTickProvider.overrideWithValue(0),
      databaseProvider.overrideWithValue(db),
      notificationServiceProvider
          .overrideWithValue(RecordingNotificationService()),
    ]);
    addTearDown(container.dispose);
    await container.read(syncedPreferencesProvider.future);
    await tester.runAsync(() => container
        .read(shutdownSettingsProvider.notifier)
        .setShutdownTime(shutdownTime));

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SettingsScreen()),
    ));
    await tester.pumpAndSettle();

    final tile = find.byKey(tileKey);
    await tester.scrollUntilVisible(tile, 200);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  }

  testWidgets('row 21: a Daily Planning time equal to the Evening Shutdown '
      'time is refused', (tester) async {
    await acceptPickerOn(tester, const Key('planning_time_tile'),
        shutdownTime: const TimeOfDay(hour: 8, minute: 0));
    expect(find.text(_refusal), findsOneWidget);
  });

  testWidgets('row 21: an Evening Shutdown time equal to the Daily Planning '
      'time is refused', (tester) async {
    await acceptPickerOn(tester, const Key('shutdown_time_tile'),
        shutdownTime: const TimeOfDay(hour: 8, minute: 0));
    expect(find.text(_refusal), findsOneWidget);
  });

  testWidgets('row 21: different times are accepted', (tester) async {
    await acceptPickerOn(tester, const Key('planning_time_tile'),
        shutdownTime: const TimeOfDay(hour: 18, minute: 0));
    expect(find.text(_refusal), findsNothing);
  });
}
