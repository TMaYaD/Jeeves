/// The long Break settings in Settings (issue #911).
///
/// The real Settings screen over a real database: both settings are offered,
/// and a choice reaches the synced preferences the other devices read.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/focus_settings.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_settings_provider.dart';
import 'package:jeeves/providers/nudge_clock_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/screens/settings/settings_screen.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers.dart';

class _StubNotificationService extends NotificationService {
  _StubNotificationService() : super.forTesting();

  @override
  Future<bool> areNotificationsAllowed() async => true;

  @override
  Future<void> cancelReminder(int id) async {}

  @override
  Future<void> cancelAll() async {}
}

/// The value shown on the right of the row with [key].
String? _value(WidgetTester tester, Key key) =>
    tester.widget<Text>(find.byKey(key)).data;

Future<ProviderContainer> _pumpSettings(WidgetTester tester) async {
  final db = GtdDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      nudgeBoundaryTickProvider.overrideWithValue(0),
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
  return container;
}

/// Brings the tile with [key] into view.
Future<void> _reveal(WidgetTester tester, Key key) async {
  await tester.scrollUntilVisible(find.byKey(key), 200);
  await tester.ensureVisible(find.byKey(key));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(configureSqliteForTests);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('both long Break settings are offered with their defaults',
      (tester) async {
    await _pumpSettings(tester);

    await _reveal(tester, const Key('focus_long_break_tile'));
    expect(find.text('Long break'), findsOneWidget);
    expect(_value(tester, const Key('focus_long_break_value')), '15m');
    expect(find.text('After a run of Sprints.'), findsOneWidget);

    await _reveal(tester, const Key('focus_sprints_before_long_break_tile'));
    expect(find.text('Sprints before a long break'), findsOneWidget);
    expect(
        _value(tester, const Key('focus_sprints_before_long_break_value')), '4');
    expect(
      find.text(
        'The count starts over after a long break, or after a gap with no '
        'Sprint as long as a long break.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a long Break length is chosen and stored', (tester) async {
    final container = await _pumpSettings(tester);

    await _reveal(tester, const Key('focus_long_break_tile'));
    await tester.tap(find.byKey(const Key('focus_long_break_tile')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('25 minutes'));
    await tester.pumpAndSettle();

    expect(container.read(focusSettingsProvider).longBreakDurationMinutes, 25);
    expect(
      container.read(syncedPreferencesProvider).asData!.value
          .get<int>(kFocusLongBreakDurationMinutesPrefKey),
      25,
    );
    expect(_value(tester, const Key('focus_long_break_value')), '25m');
  });

  testWidgets('a number of Sprints before a long Break is chosen and stored',
      (tester) async {
    final container = await _pumpSettings(tester);

    await _reveal(tester, const Key('focus_sprints_before_long_break_tile'));
    await tester
        .tap(find.byKey(const Key('focus_sprints_before_long_break_tile')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('6 sprints'));
    await tester.pumpAndSettle();

    expect(container.read(focusSettingsProvider).sprintsBeforeLongBreak, 6);
    expect(
      container.read(syncedPreferencesProvider).asData!.value
          .get<int>(kFocusSprintsBeforeLongBreakPrefKey),
      6,
    );
    expect(
        _value(tester, const Key('focus_sprints_before_long_break_value')), '6');
  });
}
