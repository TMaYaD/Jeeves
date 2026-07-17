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
import 'package:jeeves/models/focus_settings.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/focus_settings_provider.dart';
import 'package:jeeves/screens/focus_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

// ---------------------------------------------------------------------------
// Mock notifiers
// ---------------------------------------------------------------------------

/// Counts [FocusSessionPlanningNotifier.reEnterPlanning] calls so tests can
/// pin when the "Plan the Day" entry resets planning state. Reset in setUp.
int _reEnterPlanningCalls = 0;

class _MockFocusSessionPlanningNotifier extends FocusSessionPlanningNotifier {
  @override
  FocusSessionPlanningState build() {
    // Skip _preloadRolloverIds microtask so databaseProvider is not needed.
    return const FocusSessionPlanningState();
  }

  @override
  Future<void> reEnterPlanning() async {
    _reEnterPlanningCalls++;
    state = const FocusSessionPlanningState();
  }
}

class _MockFocusSettingsNotifier extends FocusSettingsNotifier {
  @override
  FocusSettings build() => const FocusSettings();
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
      focusSettingsProvider
          .overrideWith(() => _MockFocusSettingsNotifier()),
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
    _reEnterPlanningCalls = 0;
  });

  testWidgets('FocusScreen renders without auto-navigating when planning is incomplete',
      (tester) async {
    await tester.pumpWidget(_buildScreen());
    await tester.pump();

    // Must stay on /focus — no automatic redirect to /focus-session-planning.
    expect(find.text('planning'), findsNothing);
    expect(find.byType(FocusScreen), findsOneWidget);
  });

  testWidgets('FocusScreen header reads "Now" (design review: Focus ↔ Now)',
      (tester) async {
    await tester.pumpWidget(_buildScreen());
    await tester.pump();

    // The execution home screen's user-facing title is "Now"; the internal
    // name stays Focus (route /focus, FocusScreen).
    expect(find.text('Now'), findsOneWidget);
    expect(find.text('Focus'), findsNothing);
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

  testWidgets(
      'Plan the Day does not reset an abandoned draft — the next performance '
      'is seeded from it (issue #180, D3)', (tester) async {
    focusSessionPlanningCompletionNotifier.value = false;
    await tester.pumpWidget(_buildScreen());
    await tester.pump();

    await tester.tap(find.text('Plan the Day'));
    await tester.pumpAndSettle();

    expect(find.text('planning'), findsOneWidget);
    expect(_reEnterPlanningCalls, 0,
        reason: 'an incomplete (abandoned or virgin) performance must not '
            'be reset on entry — the retained state is the seed draft');
  });

  testWidgets(
      'Plan the Day after a completed performance resets via reEnterPlanning',
      (tester) async {
    focusSessionPlanningCompletionNotifier.value = true;
    await tester.pumpWidget(_buildScreen());
    await tester.pump();

    await tester.tap(find.text('Plan the Day'));
    await tester.pumpAndSettle();

    expect(find.text('planning'), findsOneWidget);
    expect(_reEnterPlanningCalls, 1,
        reason: 'post-completion Re-plan keeps the reset behaviour');
  });

  testWidgets(
      'FocusScreen shows End Session button when session is active and all tasks are done',
      (tester) async {
    // The shutdown footer only appears once planning is complete and there is
    // at least one task on the session. Within that footer, the "End Session"
    // variant requires every task to be done; otherwise the screen surfaces
    // "Begin Evening Shutdown" to route the user into the shutdown ritual.
    focusSessionPlanningCompletionNotifier.value = true;

    // startedAt is stored as ISO-8601 text (TextColumn in the Drift schema).
    final fakeSession = FocusSession(
      id: 'test-session',
      userId: 'test-user',
      startedAt: DateTime.now().toIso8601String(),
      endedAt: null,
      currentTaskId: null,
    );

    final now = DateTime.now();
    final doneTask = Todo(
      id: 'task-1',
      title: 'Done task',
      createdAt: now,
      doneAt: now.toUtc().toIso8601String(),
      clarified: true,
      intent: 'next',
      userId: 'test-user',
      timeSpentMinutes: 0,
    );

    await tester.pumpWidget(
      _buildScreen(tasks: [doneTask], activeSession: fakeSession),
    );
    await tester.pump();

    expect(find.text('End Session'), findsOneWidget);
    expect(find.text('Plan the Day'), findsNothing);
  });
}
