import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/clarify_mode.dart';
import 'package:jeeves/providers/clarify_mode_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/screens/settings/settings_screen.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

/// The sibling ceremony settings on this screen reschedule their reminders as
/// soon as preferences load, which reaches the platform channel and the
/// uninitialised timezone database. No-op them so the clarify tiles can be
/// exercised in isolation.
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

void main() {
  setUpAll(configureSqliteForTests);

  group('SettingsScreen — clarify mode', () {
    late GtdDatabase db;
    late ProviderContainer container;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      db = GtdDatabase(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          notificationServiceProvider
              .overrideWithValue(_StubNotificationService()),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    Widget buildScreen() => UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: GoRouter(
              initialLocation: '/settings',
              routes: [
                GoRoute(
                  path: '/settings',
                  builder: (_, _) => const SettingsScreen(),
                ),
              ],
            ),
          ),
        );

    Future<void> disposeScreen(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }

    testWidgets('exposes the clarify mode, defaulting to one-to-one',
        (tester) async {
      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.byKey(const Key('clarify_mode_tile')),
        200,
      );
      expect(find.text('Clarify mode'), findsOneWidget);
      expect(find.text('One Capture, one Outcome'), findsOneWidget);

      await disposeScreen(tester);
    });

    testWidgets('picking split and merge persists the mode', (tester) async {
      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.byKey(const Key('clarify_mode_tile')),
        200,
      );
      await tester.tap(find.byKey(const Key('clarify_mode_tile')));
      await tester.pumpAndSettle();

      await tester
          .tap(find.byKey(const Key('clarify_mode_option_nToM')));
      await tester.pumpAndSettle();

      expect(container.read(clarifyModeProvider), ClarifyMode.nToM);
      // The tile's summary follows the stored mode.
      expect(find.text('Split and merge Captures'), findsOneWidget);

      await disposeScreen(tester);
    });

    testWidgets('dismissing the picker leaves the mode untouched',
        (tester) async {
      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.byKey(const Key('clarify_mode_tile')),
        200,
      );
      await tester.tap(find.byKey(const Key('clarify_mode_tile')));
      await tester.pumpAndSettle();

      // Tap the barrier to dismiss without choosing.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(container.read(clarifyModeProvider), ClarifyMode.oneToOne);

      await disposeScreen(tester);
    });
  });
}
