/// Regression coverage for the sprint surface losing its subject (#428).
///
/// `ActiveFocusScreen` is the one subject-bound site that deliberately does
/// *not* render a missing panel: focus is a sprint on a single task, so when
/// that task is gone there is nothing left to focus on and the screen bounces
/// to the focus home instead. What the pre-#428 code got wrong was doing it
/// *silently* — and rendering `Error: $e` at the user on the error branch.
library;

import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_provider.dart';
import 'package:jeeves/providers/sprint_timer_provider.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/screens/active_focus_screen.dart';
import 'package:jeeves/services/notification_service.dart';
import '../test_helpers.dart';

const _userId = 'local';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

Future<Todo> _insertTodo(
  GtdDatabase db, {
  required String id,
  String title = 'Sprint task',
}) async {
  await db.customInsert(
    'INSERT INTO todos (id, title, user_id, created_at, time_spent_minutes, intent) '
    'VALUES (?, ?, ?, ?, ?, ?)',
    variables: [
      Variable.withString(id),
      Variable.withString(title),
      Variable.withString(_userId),
      Variable.withDateTime(DateTime.now()),
      Variable.withInt(0),
      Variable.withString('next'),
    ],
  );
  return (await db.todoDao.getTodo(id))!;
}

/// No-op [NotificationService] — flutter_local_notifications resolves a
/// platform implementation that does not exist under the unit-test binding,
/// so every method the sprint touches is overridden to silently return.
class _StubNotificationService extends NotificationService {
  _StubNotificationService() : super.forTesting();

  /// Counts the persistent focus notification being torn down. Recorded rather
  /// than merely swallowed because cancelling it is load-bearing on the
  /// missing-task path: left standing, the status-bar notification keeps
  /// deep-linking back into a sprint whose task no longer exists.
  int cancelFocusCalls = 0;

  @override
  Future<void> showFocusNotification({
    required String title,
    required String body,
  }) async {}

  @override
  Future<void> cancelFocusNotification() async {
    cancelFocusCalls++;
  }

  @override
  Future<void> scheduleSprintEndNotification({
    required DateTime endTime,
    required String taskTitle,
  }) async {}

  @override
  Future<void> scheduleBreakEndNotification({
    required DateTime endTime,
  }) async {}

  @override
  Future<void> cancelSprintNotifications() async {}
}

/// Records sprint lifecycle calls without running the real ticker.
///
/// The real [SprintTimerNotifier] drives a `Timer.periodic` that lives in the
/// provider container rather than the widget, so it outlives the screen and
/// trips the binding's "a Timer is still pending" teardown check. Substituting
/// it keeps this file focused on what #428 changed — that losing the subject
/// tears the sprint down — instead of on the timer's own machinery, which
/// sprint_timer_provider_test already covers.
class _RecordingSprintTimer extends SprintTimerNotifier {
  _RecordingSprintTimer(this._taskId);

  final String _taskId;
  int stopCalls = 0;

  @override
  SprintTimerState build() =>
      SprintTimerState(phase: SprintPhase.focus, activeTaskId: _taskId);

  @override
  Future<void> startSprint(Todo task) async {}

  @override
  Future<void> stopSprint() async {
    stopCalls++;
    state = const SprintTimerState();
  }
}

/// A sprint whose teardown fails — a PowerSync write rejected mid-close, say.
/// The bounce must still get the user off a screen bound to a deleted task:
/// the redirect is guarded by `_missingBounceScheduled`, so a throw that
/// escapes the post-frame callback strands them on a blank surface with no
/// second attempt coming.
class _FailingSprintTimer extends SprintTimerNotifier {
  _FailingSprintTimer(this._taskId);

  final String _taskId;
  int stopCalls = 0;

  @override
  SprintTimerState build() =>
      SprintTimerState(phase: SprintPhase.focus, activeTaskId: _taskId);

  @override
  Future<void> startSprint(Todo task) async {}

  /// Mirrors the real [SprintTimerNotifier.stopSprint] contract: the local
  /// state reset happens in a `finally`, so it survives the throw. Modelled
  /// rather than simply throwing, because a fake that stayed active would let
  /// this file assert a bounce over a phantom sprint that production no longer
  /// leaves behind. The invariant itself is pinned against the real notifier in
  /// sprint_timer_provider_test.dart; this fake only has to not contradict it.
  @override
  Future<void> stopSprint() async {
    stopCalls++;
    try {
      throw StateError('sprint teardown failed');
    } finally {
      state = const SprintTimerState();
    }
  }
}

/// Seeds the focus state as already-active on [_todoId], so the test starts
/// where the user would be: mid-sprint. Seeding initial state, not stubbing
/// behaviour — every method still runs the real implementation.
class _ActiveFocusNotifier extends FocusModeNotifier {
  _ActiveFocusNotifier(this._todoId);

  final String _todoId;

  @override
  FocusModeState build() =>
      FocusModeState(activeTodoId: _todoId, sessionStart: DateTime.now());
}

(Widget, GoRouter) _buildScreen(
  GtdDatabase db,
  String todoId, {
  required Stream<Todo?> todoStream,
  SprintTimerNotifier? sprint,
  _StubNotificationService? notifications,
}) {
  final router = GoRouter(
    initialLocation: '/focus/active',
    routes: [
      GoRoute(
        path: '/focus',
        builder: (_, _) => const Scaffold(body: Text('Focus home')),
      ),
      GoRoute(
        path: '/focus/active',
        builder: (_, _) => const ActiveFocusScreen(),
      ),
    ],
  );

  final widget = ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      notificationServiceProvider
          .overrideWithValue(notifications ?? _StubNotificationService()),
      focusModeProvider.overrideWith(() => _ActiveFocusNotifier(todoId)),
      if (sprint != null) sprintTimerProvider.overrideWith(() => sprint),
      taskDetailTodoProvider(todoId).overrideWith((_) => todoStream),
    ],
    child: MaterialApp.router(routerConfig: router),
  );

  return (widget, router);
}

void main() {
  setUpAll(configureSqliteForTests);

  group('ActiveFocusScreen — task deleted mid-sprint (#428)', () {
    late GtdDatabase db;

    setUp(() {
      // sprintTimerProvider restores its state from SharedPreferences.
      SharedPreferences.setMockInitialValues({});
      db = _openInMemory();
    });
    tearDown(() async => db.close());

    testWidgets(
        'a task hard-deleted mid-sprint bounces to focus home and says why',
        (tester) async {
      final todo = await _insertTodo(db, id: 'sp1', title: 'Write the spec');
      final subject = StreamController<Todo?>.broadcast();
      addTearDown(subject.close);

      final sprint = _RecordingSprintTimer('sp1');
      final notifications = _StubNotificationService();
      final (widget, _) = _buildScreen(
        db,
        'sp1',
        todoStream: subject.stream,
        sprint: sprint,
        notifications: notifications,
      );
      await tester.pumpWidget(widget);
      subject.add(todo);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Write the spec'), findsOneWidget);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(ActiveFocusScreen)),
      );
      expect(container.read(focusModeProvider).isActive, isTrue,
          reason: 'precondition: the sprint is running');

      // Sync applies a remote delete underneath the open sprint.
      subject.add(null);
      // Bounded pumping rather than pumpAndSettle: the SnackBar holds itself
      // open on a timer, so the binding never reaches a quiet frame. Enough
      // frames to carry the post-frame bounce and the route transition.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      // Sampled before asserting, because the SnackBar is transient and its
      // 4s display timer MUST be drained below or the binding tears the tree
      // down with a timer pending — which surfaces as a hang that masks
      // whichever assertion actually failed.
      final explained = find
          .text('That task no longer exists — focus ended.')
          .evaluate()
          .length;
      await tester.pump(const Duration(seconds: 5));

      // Bounced rather than stranding the user on a dead sprint...
      expect(find.text('Focus home'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // ...and explained itself, which the pre-#428 silent redirect never did.
      expect(explained, 1);
      // ...and actually ended the sprint rather than only navigating. Without
      // this the SnackBar's "focus ended" would be a lie: focus would still be
      // active on a deleted task, and the focus home would offer to resume it.
      expect(container.read(focusModeProvider).isActive, isFalse);
      expect(sprint.stopCalls, 1);
      // ...including the persistent status-bar notification. Left standing it
      // would go on deep-linking into a sprint whose task is gone.
      expect(notifications.cancelFocusCalls, 1);
    });

    testWidgets('a failing teardown still bounces the user off the dead task',
        (tester) async {
      final todo = await _insertTodo(db, id: 'sp3', title: 'Doomed');
      final subject = StreamController<Todo?>.broadcast();
      addTearDown(subject.close);

      final sprint = _FailingSprintTimer('sp3');
      final notifications = _StubNotificationService();
      final (widget, _) = _buildScreen(
        db,
        'sp3',
        todoStream: subject.stream,
        sprint: sprint,
        notifications: notifications,
      );
      await tester.pumpWidget(widget);
      subject.add(todo);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Doomed'), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ActiveFocusScreen)),
      );

      subject.add(null);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      // Sampled before the SnackBar's display timer is drained (see the note
      // on the sibling test).
      final explained = find
          .textContaining('That task no longer exists')
          .evaluate()
          .length;
      await tester.pump(const Duration(seconds: 5));

      expect(sprint.stopCalls, 1, reason: 'precondition: teardown was tried');
      // The steps run independently, so the one that failed does not suppress
      // the rest: focus mode must still be cleared even though the sprint
      // stop threw. Chaining them would leave focus active on a deleted row —
      // exactly the state the teardown exists to clear.
      expect(container.read(focusModeProvider).isActive, isFalse,
          reason: 'a failed step must not skip the ones after it');
      // The cancel runs *before* the failing stop, so this pins the other half
      // of independence: the steps around a failure all still happen. Left
      // standing, the status-bar notification keeps deep-linking into a sprint
      // whose task is gone.
      expect(notifications.cancelFocusCalls, 1,
          reason: 'a failed sprint stop must not skip notification cleanup');
      // And the failed stop must not leave a sprint behind. Clearing focus mode
      // is exactly what puts every stop control out of reach — `/focus/active`
      // bounces without an active focus, and nothing on `/focus` can stop a
      // sprint — so a sprint still reporting itself active here would be one
      // the user can neither see nor end.
      expect(container.read(sprintTimerProvider).isActive, isFalse,
          reason: 'a failed stop must not strand an unreachable sprint');
      // The bounce is one-shot — `_missingBounceScheduled` blocks a retry — so
      // a throw that escapes leaves the user on a blank surface bound to a
      // task that no longer exists, with nothing coming to rescue them.
      expect(find.text('Focus home'), findsOneWidget,
          reason: 'a failed teardown must not strand the user');
      expect(explained, 1, reason: 'and must still say what happened');
      expect(tester.takeException(), isNull);
    });

    testWidgets('an errored watch never renders the exception at the user',
        (tester) async {
      final subject = StreamController<Todo?>.broadcast();
      addTearDown(subject.close);

      final (widget, _) = _buildScreen(db, 'sp2',
          todoStream: subject.stream, sprint: _RecordingSprintTimer('sp2'));
      await tester.pumpWidget(widget);
      subject.addError(Exception('SecretInternalDetail'));
      // Bounded pumping: the error branch logs through `debugPrint`, whose
      // throttle timer keeps the binding from reaching a quiet frame.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // The leak this migration killed: the screen used to render `Error: $e`.
      expect(find.textContaining('SecretInternalDetail'), findsNothing);
      expect(find.textContaining('Something went wrong'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });
}
