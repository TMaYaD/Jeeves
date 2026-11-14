import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_settings_provider.dart';
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
  /// 08:30 (both persisted, so they differ). Then taps [tileKey], switches the
  /// picker to typed entry and sets [hour] and/or [minute] (the other field
  /// keeps the tile's own value, AM stays AM).
  Future<ProviderContainer> pickOn(
    WidgetTester tester,
    Key tileKey, {
    String? hour,
    String? minute,
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
        .setShutdownTime(const TimeOfDay(hour: 8, minute: 30)));

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SettingsScreen()),
    ));
    await tester.pumpAndSettle();

    final tile = find.byKey(tileKey);
    await tester.scrollUntilVisible(tile, 200);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.keyboard_outlined));
    await tester.pumpAndSettle();
    final fields = find.descendant(
        of: find.byType(Dialog), matching: find.byType(TextField));
    if (hour != null) await tester.enterText(fields.at(0), hour);
    if (minute != null) await tester.enterText(fields.at(1), minute);
    await tester.pump();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    return container;
  }

  TimeOfDay planningTimeOf(ProviderContainer c) =>
      c.read(focusSessionPlanningSettingsProvider).planningTime;
  TimeOfDay shutdownTimeOf(ProviderContainer c) =>
      c.read(shutdownSettingsProvider).shutdownTime;

  testWidgets('row 21: a Daily Planning time equal to the Evening Shutdown '
      'time is refused and not saved', (tester) async {
    final container = await pickOn(tester, const Key('planning_time_tile'),
        minute: '30');
    expect(find.text(_refusal), findsOneWidget);
    expect(planningTimeOf(container), const TimeOfDay(hour: 8, minute: 0));
    expect(shutdownTimeOf(container), const TimeOfDay(hour: 8, minute: 30));
    final prefs = await tester.runAsync(SharedPreferences.getInstance);
    expect(prefs!.getInt('shutdown_settings_time_minute'), 30);
  });

  testWidgets('row 21: an Evening Shutdown time equal to the Daily Planning '
      'time is refused and not saved', (tester) async {
    final container = await pickOn(tester, const Key('shutdown_time_tile'),
        minute: '00');
    expect(find.text(_refusal), findsOneWidget);
    expect(shutdownTimeOf(container), const TimeOfDay(hour: 8, minute: 30));
    expect(planningTimeOf(container), const TimeOfDay(hour: 8, minute: 0));
  });

  testWidgets('row 21: a different time is saved', (tester) async {
    final container = await pickOn(tester, const Key('planning_time_tile'),
        hour: '7');
    await tester.runAsync(() => pumpEventQueue());
    expect(find.text(_refusal), findsNothing);
    expect(planningTimeOf(container), const TimeOfDay(hour: 7, minute: 0));
  });
}
