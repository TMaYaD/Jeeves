/// Widget tests for FocusScreen pre-plan and post-plan states (issue #225).
///
/// The screen must be unconditionally accessible and must display a prominent
/// "Plan the Day" CTA when no active session exists, rather than relying on a
/// router redirect to force the user into planning.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/screens/focus_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

// ---------------------------------------------------------------------------
// Mock notifiers
// ---------------------------------------------------------------------------

class _MockFocusSessionPlanningNotifier extends FocusSessionPlanningNotifier {
  @override
  FocusSessionPlanningState build() {
    // Skip _preloadRolloverIds microtask so databaseProvider is not needed.
    return const FocusSessionPlanningState();
  }

  @override
  Future<void> reEnterPlanning() async {
    state = const FocusSessionPlanningState();
  }
}

// ---------------------------------------------------------------------------
// Test helper
// ---------------------------------------------------------------------------

Widget _buildScreen({
  List<Todo> tasks = const [],
  FocusSession? activeSession,
}) {
  final router = GoRouter(
    initialLocation: '/focus',
    routes: [
      GoRoute(
        path: '/focus',
        builder: (_, _) => const FocusScreen(),
      ),
      GoRoute(
        path: '/focus-session-planning',
        builder: (_, _) => const Scaffold(body: Text('planning')),
      ),
    ],
  );

  return ProviderScope(
    overrides: [
      activeSessionTasksProvider.overrideWith(
        (_) => Stream.value(tasks),
      ),
      activeSessionProvider.overrideWith(
        (_) => Stream.value(activeSession),
      ),
      focusSessionPlanningProvider
          .overrideWith(() => _MockFocusSessionPlanningNotifier()),
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

  testWidgets('FocusScreen renders without auto-navigating when planning is incomplete',
      (tester) async {
    await tester.pumpWidget(_buildScreen());
    await tester.pump();

    // Must stay on /focus — no automatic redirect to /focus-session-planning.
    expect(find.text('planning'), findsNothing);
    expect(find.byType(FocusScreen), findsOneWidget);
  });

  testWidgets('FocusScreen shows Plan the Day button when no active session',
      (tester) async {
    await tester.pumpWidget(_buildScreen());
    await tester.pump();

    expect(find.text('Plan the Day'), findsOneWidget);
  });

  testWidgets('FocusScreen shows empty task hint when no tasks are selected',
      (tester) async {
    await tester.pumpWidget(_buildScreen());
    await tester.pump();

    expect(
      find.textContaining('No tasks selected'),
      findsOneWidget,
    );
  });

  testWidgets('tapping Plan the Day navigates to /focus-session-planning',
      (tester) async {
    await tester.pumpWidget(_buildScreen());
    await tester.pump();

    await tester.tap(find.text('Plan the Day'));
    await tester.pumpAndSettle();

    expect(find.text('planning'), findsOneWidget);
  });

  testWidgets('FocusScreen shows End Session button when session is active',
      (tester) async {
    // startedAt is stored as ISO-8601 text (TextColumn in the Drift schema).
    final fakeSession = FocusSession(
      id: 'test-session',
      userId: 'test-user',
      startedAt: DateTime.now().toIso8601String(),
      endedAt: null,
      currentTaskId: null,
    );

    await tester.pumpWidget(_buildScreen(activeSession: fakeSession));
    await tester.pump();

    expect(find.text('End Session'), findsOneWidget);
    expect(find.text('Plan the Day'), findsNothing);
  });
}
