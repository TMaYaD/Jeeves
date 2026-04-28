/// Widget tests for [FocusSessionReviewScreen].
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/providers/focus_session_review_provider.dart';
import 'package:jeeves/screens/review/focus_session_review_screen.dart';
import '../test_helpers.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Minimal Drift [Todo] row for widget tests (uses the Drift-generated class).
Todo _todo(String id, String title, {String? doneAt}) => Todo(
      id: id,
      title: title,
      notes: null,
      doneAt: doneAt,
      priority: null,
      dueDate: null,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: null,
      clarified: true,
      intent: 'next',
      timeEstimate: null,
      energyLevel: null,
      captureSource: null,
      locationId: null,
      userId: 'local',
      timeSpentMinutes: 0,
    );

class _FakeReviewNotifier extends FocusSessionReviewNotifier {
  _FakeReviewNotifier(FocusSessionReviewState initialState)
      : _initial = initialState;

  final FocusSessionReviewState _initial;
  bool submitCalled = false;
  ReviewDisposition? lastDisposition;
  String? lastDispositionTaskId;

  @override
  FocusSessionReviewState build() => _initial;

  @override
  Future<void> initFromSession(String sessionId) async {
    state = _initial.copyWith(sessionId: sessionId);
  }

  @override
  void setDisposition(String taskId, ReviewDisposition disposition) {
    lastDispositionTaskId = taskId;
    lastDisposition = disposition;
    super.setDisposition(taskId, disposition);
  }

  @override
  Future<void> submitReview({DateTime? now}) async {
    submitCalled = true;
  }
}

Widget _buildScreen(_FakeReviewNotifier notifier) {
  final router = GoRouter(
    initialLocation: '/review',
    routes: [
      GoRoute(
        path: '/review',
        builder: (_, _) =>
            const FocusSessionReviewScreen(sessionId: 'session-1'),
      ),
      GoRoute(
        path: '/inbox',
        builder: (_, _) => const Scaffold(body: Text('Inbox')),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      focusSessionReviewProvider.overrideWith(() => notifier),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(configureSqliteForTests);

  group('FocusSessionReviewScreen', () {
    testWidgets('done tasks render with strikethrough, no disposition chips',
        (tester) async {
      final notifier = _FakeReviewNotifier(FocusSessionReviewState(
        sessionId: 'session-1',
        sessionTasks: [
          _todo('t1', 'Done task', doneAt: '2026-04-28T10:00:00.000Z'),
        ],
      ));

      await tester.pumpWidget(_buildScreen(notifier));
      await tester.pump();

      expect(find.text('Done task'), findsOneWidget);
      expect(find.text('Roll Over'), findsNothing);
      expect(find.text('Leave'), findsNothing);
      expect(find.text('Maybe'), findsNothing);
    });

    testWidgets('pending tasks render with three disposition chips',
        (tester) async {
      final notifier = _FakeReviewNotifier(FocusSessionReviewState(
        sessionId: 'session-1',
        sessionTasks: [_todo('t1', 'Pending task')],
      ));

      await tester.pumpWidget(_buildScreen(notifier));
      await tester.pump();

      expect(find.text('Pending task'), findsOneWidget);
      expect(find.text('Roll Over'), findsOneWidget);
      expect(find.text('Leave'), findsOneWidget);
      expect(find.text('Maybe'), findsOneWidget);
    });

    testWidgets(
        '"Close Session" is disabled when a pending task has no disposition',
        (tester) async {
      final notifier = _FakeReviewNotifier(FocusSessionReviewState(
        sessionId: 'session-1',
        sessionTasks: [_todo('t1', 'Pending task')],
      ));

      await tester.pumpWidget(_buildScreen(notifier));
      await tester.pump();

      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Close Session'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets(
        '"Close Session" is enabled when all pending tasks have a disposition',
        (tester) async {
      final notifier = _FakeReviewNotifier(FocusSessionReviewState(
        sessionId: 'session-1',
        sessionTasks: [_todo('t1', 'Pending task')],
        dispositions: {'t1': ReviewDisposition.leave},
      ));

      await tester.pumpWidget(_buildScreen(notifier));
      await tester.pump();

      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Close Session'),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets(
        '"Close Session" is enabled immediately when all tasks are done',
        (tester) async {
      final notifier = _FakeReviewNotifier(FocusSessionReviewState(
        sessionId: 'session-1',
        sessionTasks: [
          _todo('t1', 'Done task', doneAt: '2026-04-28T10:00:00.000Z'),
        ],
      ));

      await tester.pumpWidget(_buildScreen(notifier));
      await tester.pump();

      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Close Session'),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('tapping a chip calls setDisposition with the correct enum',
        (tester) async {
      final notifier = _FakeReviewNotifier(FocusSessionReviewState(
        sessionId: 'session-1',
        sessionTasks: [_todo('t1', 'Pending task')],
      ));

      await tester.pumpWidget(_buildScreen(notifier));
      await tester.pump();

      await tester.tap(find.text('Roll Over'));
      await tester.pump();

      expect(notifier.lastDispositionTaskId, 't1');
      expect(notifier.lastDisposition, ReviewDisposition.rollover);
    });

    testWidgets('tapping "Close Session" calls submitReview', (tester) async {
      final notifier = _FakeReviewNotifier(FocusSessionReviewState(
        sessionId: 'session-1',
        sessionTasks: [_todo('t1', 'Pending task')],
        dispositions: {'t1': ReviewDisposition.rollover},
      ));

      await tester.pumpWidget(_buildScreen(notifier));
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, 'Close Session'));
      await tester.pump();

      expect(notifier.submitCalled, isTrue);
    });
  });
}
