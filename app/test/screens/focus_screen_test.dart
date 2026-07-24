/// Widget tests for FocusScreen pre-plan and post-plan states (issues #225,
/// #460).
///
/// The screen must be unconditionally accessible and must display a prominent
/// "Plan the Day" CTA when no active session exists, rather than relying on a
/// router redirect to force the user into planning. "Planning done" derives
/// from persistent session data — an open FocusSession exists — not an
/// in-memory notifier, so it survives process death (ADR-0020).
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

class _MockFocusSessionPlanningNotifier extends FocusSessionPlanningNotifier {
  @override
  FocusSessionPlanningState build() {
    // Skip _preloadRolloverIds microtask so databaseProvider is not needed.
    return const FocusSessionPlanningState();
  }
}

class _MockFocusSettingsNotifier extends FocusSettingsNotifier {
  @override
  FocusSettings build() => const FocusSettings();
}

// ---------------------------------------------------------------------------
// Test helper
// ---------------------------------------------------------------------------

FocusSession _openSession() => FocusSession(
      id: 'test-session',
      userId: 'test-user',
      startedAt: DateTime.now().toIso8601String(),
      endedAt: null,
      currentTaskId: null,
    );

Todo _todo(String id, String title, {String? doneAt}) => Todo(
      id: id,
      title: title,
      createdAt: DateTime.now(),
      doneAt: doneAt,
      clarified: true,
      intent: 'next',
      userId: 'test-user',
      timeSpentMinutes: 0,
    );

Widget _buildScreen({
  List<Todo> tasks = const [],
  FocusSession? activeSession,
  List<Todo> rolloverTasks = const [],
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
      lastClosedSessionRolloverTasksProvider.overrideWith(
        (_) => Stream.value(rolloverTasks),
      ),
      focusSessionPlanningProvider
          .overrideWith(() => _MockFocusSessionPlanningNotifier()),
      focusSettingsProvider.overrideWith(() => _MockFocusSettingsNotifier()),
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
  });

  testWidgets(
      'FocusScreen renders without auto-navigating when no session is open',
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

    expect(find.textContaining('No tasks selected'), findsOneWidget);
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
      'planning-done derives from an open session: tasks render as today\'s '
      'plan, not carried over (issue #460)', (tester) async {
    // An open session exists with a planned task → the screen shows it as
    // today's plan, with the Shutdown callout, and no "Carried over" section.
    await tester.pumpWidget(_buildScreen(
      activeSession: _openSession(),
      tasks: [_todo('t1', 'Planned task')],
      // Even with a stale last-closed rollover, an open session suppresses it.
      rolloverTasks: [_todo('r1', 'Old rollover')],
    ));
    await tester.pump();

    expect(find.text('Planned task'), findsOneWidget);
    expect(find.text('CARRIED OVER FROM LAST SESSION'), findsNothing);
    expect(find.text('Old rollover'), findsNothing);
    expect(find.text('Plan the Day'), findsNothing);
    expect(find.text('Begin Evening Shutdown'), findsOneWidget);
  });

  testWidgets(
      'carried-over section shows last-closed rollover tasks with the new '
      'copy only when no session is open (issue #460)', (tester) async {
    await tester.pumpWidget(_buildScreen(
      activeSession: null,
      rolloverTasks: [_todo('r1', 'Carried task')],
    ));
    // Two pumps: one for the active-session/tasks streams, one for the
    // rollover stream to emit into the carried-over section.
    await tester.pump();
    await tester.pump();

    expect(find.text('CARRIED OVER FROM LAST SESSION'), findsOneWidget);
    expect(find.text('Carried task'), findsOneWidget);
    // No session ⇒ the plan CTA, not the shutdown callout.
    expect(find.text('Plan the Day'), findsOneWidget);
    expect(find.text('Begin Evening Shutdown'), findsNothing);
  });

  testWidgets(
      'FocusScreen shows End Session button when session is active and all '
      'tasks are done', (tester) async {
    // The shutdown footer only appears once a session is open with at least
    // one task on it. The "End Session" variant requires every task done;
    // otherwise the screen surfaces "Begin Evening Shutdown".
    final doneTask =
        _todo('task-1', 'Done task', doneAt: DateTime.now().toUtc().toIso8601String());

    await tester.pumpWidget(
      _buildScreen(tasks: [doneTask], activeSession: _openSession()),
    );
    await tester.pump();

    expect(find.text('End Session'), findsOneWidget);
    expect(find.text('Plan the Day'), findsNothing);
  });
}
