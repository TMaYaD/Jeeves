import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/models/focus_session_planning_settings.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/focus_session_planning_settings_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/onboarding_provider.dart';
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
// Test helpers
// ---------------------------------------------------------------------------

Todo _fakeTodo() => Todo(
      id: 'fake-id',
      title: 'Fake Todo',
      notes: null,
      doneAt: null,
      priority: null,
      dueDate: null,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: null,
      clarified: false,
      intent: 'next',
      timeEstimate: null,
      energyLevel: null,
      captureSource: 'manual',
      locationId: null,
      userId: 'local',
      timeSpentMinutes: 0,
    );

Widget _buildBanner({
  required bool planningComplete,
  required bool bannerDismissed,
  required bool bannerEnabled,
  Stream<bool>? hasTodosStream,
  Stream<List<Todo>>? inboxStream,
  Stream<List<Todo>>? nextStream,
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
      hasTodosProvider.overrideWith(
          (ref) => hasTodosStream ?? Stream.value(true)),
      unfilteredInboxProvider.overrideWith(
          (ref) => inboxStream ?? Stream.value([_fakeTodo()])),
      unfilteredNextActionsProvider.overrideWith(
          (ref) => nextStream ?? Stream.value([])),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

/// Pump widget plus two extra frames so all StreamProviders transition from
/// AsyncLoading to AsyncData before the assertion runs.
Future<void> _pumpBanner(WidgetTester tester, Widget widget) async {
  await tester.pumpWidget(widget);
  await tester.pump(); // stream emits
  await tester.pump(); // widget rebuilds with emitted values
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
    await _pumpBanner(
      tester,
      _buildBanner(
        planningComplete: false,
        bannerDismissed: false,
        bannerEnabled: true,
      ),
    );

    expect(find.byKey(const Key('planning_banner_visible')), findsOneWidget);
  });

  testWidgets('banner hidden when ritual is complete', (tester) async {
    await _pumpBanner(
      tester,
      _buildBanner(
        planningComplete: true,
        bannerDismissed: false,
        bannerEnabled: true,
      ),
    );

    expect(find.byKey(const Key('planning_banner_visible')), findsNothing);
  });

  testWidgets('banner hidden when dismissed today', (tester) async {
    await _pumpBanner(
      tester,
      _buildBanner(
        planningComplete: false,
        bannerDismissed: true,
        bannerEnabled: true,
      ),
    );

    expect(find.byKey(const Key('planning_banner_visible')), findsNothing);
  });

  testWidgets('banner hidden when bannerEnabled is false', (tester) async {
    await _pumpBanner(
      tester,
      _buildBanner(
        planningComplete: false,
        bannerDismissed: false,
        bannerEnabled: false,
      ),
    );

    expect(find.byKey(const Key('planning_banner_visible')), findsNothing);
  });

  testWidgets('tapping banner navigates to /focus-session-planning',
      (tester) async {
    await _pumpBanner(
      tester,
      _buildBanner(
        planningComplete: false,
        bannerDismissed: false,
        bannerEnabled: true,
      ),
    );

    await tester.tap(find.byKey(const Key('planning_banner_visible')));
    await tester.pumpAndSettle();

    expect(find.text('planning'), findsOneWidget);
  });

  testWidgets('dismiss button hides banner', (tester) async {
    final mockPlanning = _MockFocusSessionPlanningNotifier();

    await _pumpBanner(
      tester,
      _buildBanner(
        planningComplete: false,
        bannerDismissed: false,
        bannerEnabled: true,
        planningNotifier: mockPlanning,
      ),
    );

    expect(find.byKey(const Key('planning_banner_visible')), findsOneWidget);

    await tester.tap(find.byKey(const Key('planning_banner_dismiss')));
    // pumpAndSettle drains the gesture-debounce timer created by the tap.
    // It settles immediately because the banner (and its animation) is gone.
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('planning_banner_visible')), findsNothing);
    expect(mockPlanning.bannerDismissed, isTrue);
  });

  testWidgets('completing ritual hides visible banner', (tester) async {
    await _pumpBanner(
      tester,
      _buildBanner(
        planningComplete: false,
        bannerDismissed: false,
        bannerEnabled: true,
      ),
    );

    expect(find.byKey(const Key('planning_banner_visible')), findsOneWidget);

    // Simulate ritual completion.
    focusSessionPlanningCompletionNotifier.value = true;
    await tester.pump();

    expect(find.byKey(const Key('planning_banner_visible')), findsNothing);
  });

  // ---------------------------------------------------------------------------
  // New suppression conditions (issue #258)
  // ---------------------------------------------------------------------------

  testWidgets('banner hidden when no todos exist (onboarding state)',
      (tester) async {
    await _pumpBanner(
      tester,
      _buildBanner(
        planningComplete: false,
        bannerDismissed: false,
        bannerEnabled: true,
        hasTodosStream: Stream.value(false),
      ),
    );

    expect(find.byKey(const Key('planning_banner_visible')), findsNothing);
  });

  testWidgets('banner hidden when inbox and next actions are both empty',
      (tester) async {
    await _pumpBanner(
      tester,
      _buildBanner(
        planningComplete: false,
        bannerDismissed: false,
        bannerEnabled: true,
        inboxStream: Stream.value([]),
        nextStream: Stream.value([]),
      ),
    );

    expect(find.byKey(const Key('planning_banner_visible')), findsNothing);
  });

  testWidgets('banner visible when inbox has items and next actions empty',
      (tester) async {
    await _pumpBanner(
      tester,
      _buildBanner(
        planningComplete: false,
        bannerDismissed: false,
        bannerEnabled: true,
        inboxStream: Stream.value([_fakeTodo()]),
        nextStream: Stream.value([]),
      ),
    );

    expect(find.byKey(const Key('planning_banner_visible')), findsOneWidget);
  });

  testWidgets('banner visible when inbox empty and next actions has items',
      (tester) async {
    await _pumpBanner(
      tester,
      _buildBanner(
        planningComplete: false,
        bannerDismissed: false,
        bannerEnabled: true,
        inboxStream: Stream.value([]),
        nextStream: Stream.value([_fakeTodo()]),
      ),
    );

    expect(find.byKey(const Key('planning_banner_visible')), findsOneWidget);
  });

  testWidgets('banner hidden while hasTodosProvider is loading',
      (tester) async {
    // A stream that never emits keeps the provider in AsyncLoading.
    final neverStream = Stream<bool>.empty();

    await tester.pumpWidget(_buildBanner(
      planningComplete: false,
      bannerDismissed: false,
      bannerEnabled: true,
      hasTodosStream: neverStream,
    ));
    await tester.pump();

    expect(find.byKey(const Key('planning_banner_visible')), findsNothing);
  });
}
