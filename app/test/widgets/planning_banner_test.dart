import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/planning_settings.dart';
import 'package:jeeves/providers/daily_planning_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/planning_settings_provider.dart';
import 'package:jeeves/widgets/planning_banner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../test_helpers.dart';

// ---------------------------------------------------------------------------
// Mock notifiers
// ---------------------------------------------------------------------------

class _MockDailyPlanningNotifier extends DailyPlanningNotifier {
  bool bannerDismissed = false;

  @override
  Future<void> dismissBannerForToday() async {
    bannerDismissed = true;
    bannerDismissedNotifier.value = true;
  }

  @override
  Future<void> skipPlanningToday() async {}

  @override
  Future<void> snoozePlanningNotification(int minutes) async {}
}

class _MockPlanningSettingsNotifier extends PlanningSettingsNotifier {
  _MockPlanningSettingsNotifier(this._settings);
  final PlanningSettings _settings;

  @override
  PlanningSettings build() => _settings;
}

// ---------------------------------------------------------------------------
// Test helper
// ---------------------------------------------------------------------------

Widget _buildBanner({
  required bool planningComplete,
  required bool bannerDismissed,
  required bool bannerEnabled,
  _MockDailyPlanningNotifier? planningNotifier,
}) {
  planningCompletionNotifier.value = planningComplete;
  bannerDismissedNotifier.value = bannerDismissed;

  final settings = PlanningSettings(bannerEnabled: bannerEnabled);
  final mockPlanning = planningNotifier ?? _MockDailyPlanningNotifier();

  final router = GoRouter(
    initialLocation: '/',
    routes: [
      ShellRoute(
        builder: (context, state, child) => Scaffold(
          body: Column(
            children: [
              const PlanningBanner(),
              Expanded(child: child),
            ],
          ),
        ),
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Text('home'),
          ),
        ],
      ),
      GoRoute(
        path: '/planning',
        builder: (_, _) => const Scaffold(body: Text('planning')),
      ),
    ],
  );

  return ProviderScope(
    overrides: [
      planningSettingsProvider
          .overrideWith(() => _MockPlanningSettingsNotifier(settings)),
      dailyPlanningProvider.overrideWith(() => mockPlanning),
      databaseProvider.overrideWithValue(GtdDatabase(NativeDatabase.memory())),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(configureSqliteForTests);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    planningCompletionNotifier.value = false;
    bannerDismissedNotifier.value = false;
  });

  testWidgets('banner visible when ritual incomplete and not dismissed',
      (tester) async {
    await tester.pumpWidget(_buildBanner(
      planningComplete: false,
      bannerDismissed: false,
      bannerEnabled: true,
    ));
    await tester.pump();

    expect(find.text('Plan your day \u2192'), findsOneWidget);
  });

  testWidgets('banner hidden when ritual is complete', (tester) async {
    await tester.pumpWidget(_buildBanner(
      planningComplete: true,
      bannerDismissed: false,
      bannerEnabled: true,
    ));
    await tester.pump();

    expect(find.text('Plan your day \u2192'), findsNothing);
  });

  testWidgets('banner hidden when dismissed today', (tester) async {
    await tester.pumpWidget(_buildBanner(
      planningComplete: false,
      bannerDismissed: true,
      bannerEnabled: true,
    ));
    await tester.pump();

    expect(find.text('Plan your day \u2192'), findsNothing);
  });

  testWidgets('banner hidden when bannerEnabled is false', (tester) async {
    await tester.pumpWidget(_buildBanner(
      planningComplete: false,
      bannerDismissed: false,
      bannerEnabled: false,
    ));
    await tester.pump();

    expect(find.text('Plan your day \u2192'), findsNothing);
  });

  testWidgets('tapping banner navigates to /planning', (tester) async {
    await tester.pumpWidget(_buildBanner(
      planningComplete: false,
      bannerDismissed: false,
      bannerEnabled: true,
    ));
    await tester.pump();

    await tester.tap(find.text('Plan your day \u2192'));
    await tester.pumpAndSettle();

    expect(find.text('planning'), findsOneWidget);
  });

  testWidgets('dismiss button hides banner', (tester) async {
    final mockPlanning = _MockDailyPlanningNotifier();

    await tester.pumpWidget(_buildBanner(
      planningComplete: false,
      bannerDismissed: false,
      bannerEnabled: true,
      planningNotifier: mockPlanning,
    ));
    await tester.pump();

    expect(find.text('Plan your day \u2192'), findsOneWidget);

    await tester.tap(find.byKey(const Key('planning_banner_dismiss')));
    await tester.pump();

    expect(find.text('Plan your day \u2192'), findsNothing);
    expect(mockPlanning.bannerDismissed, isTrue);
  });

  testWidgets('completing ritual hides visible banner', (tester) async {
    await tester.pumpWidget(_buildBanner(
      planningComplete: false,
      bannerDismissed: false,
      bannerEnabled: true,
    ));
    await tester.pump();

    expect(find.text('Plan your day \u2192'), findsOneWidget);

    // Simulate ritual completion.
    planningCompletionNotifier.value = true;
    await tester.pump();

    expect(find.text('Plan your day \u2192'), findsNothing);
  });
}
