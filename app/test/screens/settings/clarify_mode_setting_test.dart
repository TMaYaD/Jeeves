import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/clarify_mode.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/clarify_mode_provider.dart';
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

/// Pumps the real Settings screen so the clarify-mode tile is exercised in the
/// widget tree it actually ships in.
///
/// [initialMode] seeds the persisted preference before the screen builds, so a
/// test can start from a non-default mode. Without it every case would begin at
/// `oneToOne` and the reverse transition — plus any assertion that dismissing
/// leaves the mode *untouched* rather than resetting it to the default — would
/// be untestable.
Future<ProviderContainer> _pumpSettings(
  WidgetTester tester, {
  ClarifyMode? initialMode,
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
  if (initialMode != null) {
    await container.read(clarifyModeProvider.notifier).setMode(initialMode);
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

  group('Settings — clarify mode', () {
    testWidgets('renders the tile with canonical copy and the 1-1 default',
        (tester) async {
      await _pumpSettings(tester);

      await tester.scrollUntilVisible(
        find.byKey(const Key('clarify_mode_tile')),
        200,
      );

      expect(find.text('Clarify mode'), findsOneWidget);
      // Canonical vocabulary per CONTEXT.md § GTD Core.
      expect(
        find.textContaining('1-1 mode'),
        findsOneWidget,
        reason: 'the default mode label must read as 1-1',
      );
      expect(find.textContaining('Capture'), findsWidgets);
    });

    testWidgets('picking n-m persists the mode', (tester) async {
      final container = await _pumpSettings(tester);

      await tester.scrollUntilVisible(
        find.byKey(const Key('clarify_mode_tile')),
        200,
      );
      await tester.tap(find.byKey(const Key('clarify_mode_tile')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('clarify_mode_option_nToM')));
      await tester.pumpAndSettle();

      expect(container.read(clarifyModeProvider), ClarifyMode.nToM);
      expect(
        container
            .read(syncedPreferencesProvider)
            .asData!
            .value
            .get<String>('clarify_mode'),
        'nToM',
      );
    });

    testWidgets('picking 1-1 from n-m persists the mode back', (tester) async {
      final container =
          await _pumpSettings(tester, initialMode: ClarifyMode.nToM);

      await tester.scrollUntilVisible(
        find.byKey(const Key('clarify_mode_tile')),
        200,
      );
      await tester.tap(find.byKey(const Key('clarify_mode_tile')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('clarify_mode_option_oneToOne')));
      await tester.pumpAndSettle();

      // The return trip has to persist too: a user who tries n-m must be able
      // to get back to the shipped 1-1 flow.
      expect(container.read(clarifyModeProvider), ClarifyMode.oneToOne);
      expect(
        container
            .read(syncedPreferencesProvider)
            .asData!
            .value
            .get<String>('clarify_mode'),
        'oneToOne',
      );
    });

    testWidgets('dismissing the picker leaves the mode untouched',
        (tester) async {
      // Seeded to n-m deliberately: starting from the default would let this
      // pass even if dismissal reset the mode.
      final container =
          await _pumpSettings(tester, initialMode: ClarifyMode.nToM);

      await tester.scrollUntilVisible(
        find.byKey(const Key('clarify_mode_tile')),
        200,
      );
      await tester.tap(find.byKey(const Key('clarify_mode_tile')));
      await tester.pumpAndSettle();

      // Tap the barrier to dismiss without choosing.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(container.read(clarifyModeProvider), ClarifyMode.nToM);
      expect(
        container
            .read(syncedPreferencesProvider)
            .asData!
            .value
            .get<String>('clarify_mode'),
        'nToM',
      );
    });
  });
}
