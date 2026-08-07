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
    );

Widget _buildScreen({
  List<Todo> tasks = const [],
  FocusSession? activeSession,
  List<Todo> rolloverTasks = const [],
  Map<String, SessionSettlement> settlements = const {},
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
      // `Stream.value` is the documented override shape for a StreamProvider
      // backed by a live Drift watch (docs/TESTING.md § Frontend).
      activeSessionSettlementsProvider.overrideWith(
        (_) => Stream.value(settlements),
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

  // ---------------------------------------------------------------------------
  // Settlement strike-off (#693)
  // ---------------------------------------------------------------------------

  testWidgets(
      'a task Settled to a non-done verdict is struck off and offers no '
      'Start button (#693 AC1/AC2)', (tester) async {
    await tester.pumpWidget(_buildScreen(
      activeSession: _openSession(),
      tasks: [_todo('t1', 'Resolved task'), _todo('t2', 'Untouched task')],
      settlements: const {'t1': SessionSettlement.next},
    ));
    await tester.pump();

    // Strike-off is the acceptance criterion itself — a state signal on the
    // row, not a design token — so it is asserted directly.
    final struck = tester.widget<Text>(find.text('Resolved task'));
    expect(struck.style?.decoration, TextDecoration.lineThrough);
    final untouched = tester.widget<Text>(find.text('Untouched task'));
    expect(untouched.style?.decoration, isNot(TextDecoration.lineThrough));

    // A Settled row is handled for this session: exactly one Start remains,
    // and it belongs to the untouched task.
    expect(find.text('Start'), findsOneWidget);
  });

  testWidgets(
      'an Outcome-completed task still strikes off as it does today '
      '(#693 AC4)', (tester) async {
    final doneAt = DateTime.now().toUtc().toIso8601String();
    await tester.pumpWidget(_buildScreen(
      activeSession: _openSession(),
      tasks: [_todo('t1', 'Achieved task', doneAt: doneAt)],
      settlements: const {'t1': SessionSettlement.done},
    ));
    await tester.pump();

    final struck = tester.widget<Text>(find.text('Achieved task'));
    expect(struck.style?.decoration, TextDecoration.lineThrough);
    expect(find.text('Start'), findsNothing);
  });

  testWidgets(
      'a session whose Plan is entirely Settled but not all done still routes '
      'through Evening Shutdown (#693 AC3)', (tester) async {
    await tester.pumpWidget(_buildScreen(
      activeSession: _openSession(),
      tasks: [_todo('t1', 'Waiting task'), _todo('t2', 'Re-planned task')],
      settlements: const {
        't1': SessionSettlement.waitingFor,
        't2': SessionSettlement.next,
      },
    ));
    await tester.pump();

    // The day is finished, but Dispositions still have to be committed —
    // so the destination is the wizard, and the label says so.
    expect(find.text('Begin Evening Shutdown'), findsOneWidget);
    expect(find.text('End Session'), findsNothing);
  });

  group('focusCalloutKindFor', () {
    Todo task(String id, {String? doneAt}) => _todo(id, 'Task $id', doneAt: doneAt);
    final done = DateTime.now().toUtc().toIso8601String();

    test('every task achieved → endSession, the only closeSession state', () {
      expect(
        focusCalloutKindFor([task('a', doneAt: done)], const {
          'a': SessionSettlement.done,
        }),
        FocusCalloutKind.endSession,
      );
    });

    test('every task Settled, not all done → wrapUp', () {
      expect(
        focusCalloutKindFor(
          [task('a', doneAt: done), task('b')],
          const {'a': SessionSettlement.done, 'b': SessionSettlement.next},
        ),
        FocusCalloutKind.wrapUp,
      );
    });

    test('anything outstanding → beginShutdown', () {
      expect(
        focusCalloutKindFor(
          [task('a'), task('b')],
          const {'a': SessionSettlement.next},
        ),
        FocusCalloutKind.beginShutdown,
      );
    });
  });

  testWidgets(
      'FocusScreen no longer renders its own Re-plan ⋮ menu — Re-plan moved '
      'to the shared title bar (issue #499)', (tester) async {
    // Even in the shutdown-callout state (open session + tasks), the screen
    // itself carries no bespoke overflow menu or Re-plan affordance; the
    // Re-plan action is supplied by AppShell to the shared title bar.
    await tester.pumpWidget(_buildScreen(
      activeSession: _openSession(),
      tasks: [_todo('t1', 'Planned task')],
    ));
    await tester.pump();

    expect(find.byIcon(Icons.more_vert), findsNothing);
    expect(find.text('Re-plan'), findsNothing);
  });
}
