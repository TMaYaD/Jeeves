import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/focus_session_planning_settings.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_settings_provider.dart';
import 'package:jeeves/widgets/focus_session_planning_banner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../test_helpers.dart';

// ---------------------------------------------------------------------------
// Mock notifiers
// ---------------------------------------------------------------------------

class _MockFocusSessionPlanningNotifier extends FocusSessionPlanningNotifier {
  bool bannerDismissed = false;

  @override
  Future<void> dismissBannerForToday() async {
    bannerDismissed = true;
    focusSessionPlanningBannerDismissedNotifier.value = true;
  }

  @override
  Future<void> skipPlanningToday() async {}

  @override
  Future<void> snoozePlanningNotification(int minutes) async {}
}

class _MockFocusSessionPlanningSettingsNotifier
    extends FocusSessionPlanningSettingsNotifier {
  _MockFocusSessionPlanningSettingsNotifier(this._settings);
  final FocusSessionPlanningSettings _settings;

  @override
  FocusSessionPlanningSettings build() => _settings;
}

// ---------------------------------------------------------------------------
// Test helper
// ---------------------------------------------------------------------------

Widget _buildBanner({
  required bool planningComplete,
  required bool bannerDismissed,
  required bool bannerEnabled,
  _MockFocusSessionPlanningNotifier? planningNotifier,
}) {
  focusSessionPlanningCompletionNotifier.value = planningComplete;
  focusSessionPlanningBannerDismissedNotifier.value = bannerDismissed;

  final settings = FocusSessionPlanningSettings(bannerEnabled: bannerEnabled);
  final mockPlanning =
      planningNotifier ?? _MockFocusSessionPlanningNotifier();

  final router = GoRouter(
    initialLocation: '/',
    routes: [
      ShellRoute(
        builder: (context, state, child) => Scaffold(
          body: Column(
            children: [
              const FocusSessionPlanningBanner(),
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
        path: '/focus-session-planning',
        builder: (_, _) => const Scaffold(body: Text('planning')),
      ),
    ],
  );

  return ProviderScope(
    overrides: [
      focusSessionPlanningSettingsProvider.overrideWith(
          () => _MockFocusSessionPlanningSettingsNotifier(settings)),
      focusSessionPlanningProvider.overrideWith(() => mockPlanning),
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
    focusSessionPlanningCompletionNotifier.value = false;
    focusSessionPlanningBannerDismissedNotifier.value = false;
  });

  testWidgets('banner visible when ritual incomplete and not dismissed',
      (tester) async {
    await tester.pumpWidget(_buildBanner(
      planningComplete: false,
      bannerDismissed: false,
      bannerEnabled: true,
    ));
    await tester.pump();

    expect(find.byKey(const Key('planning_banner_visible')), findsOneWidget);
  });

  testWidgets('banner hidden when ritual is complete', (tester) async {
    await tester.pumpWidget(_buildBanner(
      planningComplete: true,
      bannerDismissed: false,
      bannerEnabled: true,
    ));
    await tester.pump();

    expect(find.byKey(const Key('planning_banner_visible')), findsNothing);
  });

  testWidgets('banner hidden when dismissed today', (tester) async {
    await tester.pumpWidget(_buildBanner(
      planningComplete: false,
      bannerDismissed: true,
      bannerEnabled: true,
    ));
    await tester.pump();

    expect(find.byKey(const Key('planning_banner_visible')), findsNothing);
  });

  testWidgets('banner hidden when bannerEnabled is false', (tester) async {
    await tester.pumpWidget(_buildBanner(
      planningComplete: false,
      bannerDismissed: false,
      bannerEnabled: false,
    ));
    await tester.pump();

    expect(find.byKey(const Key('planning_banner_visible')), findsNothing);
  });

  testWidgets('tapping banner navigates to /focus-session-planning',
      (tester) async {
    await tester.pumpWidget(_buildBanner(
      planningComplete: false,
      bannerDismissed: false,
      bannerEnabled: true,
    ));
    await tester.pump();

    await tester.tap(find.byKey(const Key('planning_banner_visible')));
    await tester.pumpAndSettle();

    expect(find.text('planning'), findsOneWidget);
  });

  testWidgets('dismiss button hides banner', (tester) async {
    final mockPlanning = _MockFocusSessionPlanningNotifier();

    await tester.pumpWidget(_buildBanner(
      planningComplete: false,
      bannerDismissed: false,
      bannerEnabled: true,
      planningNotifier: mockPlanning,
    ));
    await tester.pump();

    expect(find.byKey(const Key('planning_banner_visible')), findsOneWidget);

    await tester.tap(find.byKey(const Key('planning_banner_dismiss')));
    await tester.pump();

    expect(find.byKey(const Key('planning_banner_visible')), findsNothing);
    expect(mockPlanning.bannerDismissed, isTrue);
  });

  testWidgets('completing ritual hides visible banner', (tester) async {
    await tester.pumpWidget(_buildBanner(
      planningComplete: false,
      bannerDismissed: false,
      bannerEnabled: true,
    ));
    await tester.pump();

    expect(find.byKey(const Key('planning_banner_visible')), findsOneWidget);

    // Simulate ritual completion.
    focusSessionPlanningCompletionNotifier.value = true;
    await tester.pump();

    expect(find.byKey(const Key('planning_banner_visible')), findsNothing);
  });
}
