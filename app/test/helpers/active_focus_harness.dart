/// Shared harness for driving [ActiveFocusScreen] over a real [GtdDatabase].
///
/// Lifted out of `test/screens/active_focus_screen_test.dart` so the
/// integration-tier journey test (`reclarify_promote_planned_journey_test.dart`,
/// issue #723) can reuse it. The screen's sprint ring runs a perpetual pulse
/// animation, so `pumpAndSettle` never settles — [pumpFocusFrames] advances a
/// bounded number of real frames instead, draining the real event queue between
/// them so each verdict's drift writes land.
library;

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show FlutterLocalNotificationsPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/focus_session_provider.dart';
import 'package:jeeves/providers/sprint_timer_provider.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/screens/active_focus_screen.dart';

const focusUserId = 'local';

const focusNotificationsChannel =
    MethodChannel('dexterous.com/flutter/local_notifications');

/// A stand-in [FlutterLocalNotificationsPlatform] that is deliberately *not*
/// the Android/iOS concrete plugin. `ActiveFocusScreen` refreshes its
/// persistent notification through `NotificationService.instance`, whose plugin
/// resolves the platform-specific implementation before touching the method
/// channel — and that resolution reads `FlutterLocalNotificationsPlatform.instance`,
/// a late static that is never initialised in tests. Registering this fake both
/// satisfies that late field and, because it is not the Android plugin type,
/// makes `resolvePlatformSpecificImplementation<Android…>()` return null so
/// `show`/`cancel` become no-ops.
class FakeNotificationsPlatform extends FlutterLocalNotificationsPlatform {}

GtdDatabase openFocusInMemory() => GtdDatabase(NativeDatabase.memory());

/// Focus-mode notifier pinned active on [todoId], with a DB-free [endFocus] so
/// the session close doesn't need a real FocusSession row.
class ActiveFocusModeNotifier extends FocusModeNotifier {
  ActiveFocusModeNotifier(this.todoId);
  final String todoId;

  @override
  FocusModeState build() =>
      FocusModeState(activeTodoId: todoId, sessionStart: DateTime.now());

  @override
  Future<void> endFocus() async {
    state = const FocusModeState();
  }
}

/// Sprint timer stubbed idle — skips `_restoreFromPrefs()` and the sprint
/// start/stop side effects (haptics, notifications, DB time-log reads).
class IdleSprintTimerNotifier extends SprintTimerNotifier {
  @override
  SprintTimerState build() => const SprintTimerState();

  @override
  Future<void> startSprint(Todo task) async {}

  @override
  Future<void> stopSprint() async {}
}

Future<Todo> insertFocusTodo(
  GtdDatabase db, {
  required String id,
  String title = 'Ship the thing',
  String? notes,
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value(title),
        notes: Value(notes),
        clarified: const Value(true),
        intent: const Value('next'),
        userId: const Value(focusUserId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  return (await db.todoDao.getTodo(id))!;
}

/// Builds the router harness rendering [ActiveFocusScreen] at `/active`, with a
/// placeholder `focus-home` at `/focus`.
Widget focusHarness(
  GtdDatabase db, {
  required Todo todo,
  SprintTimerNotifier Function()? sprintTimer,
  // Stream feeding `taskDetailTodoProvider` — the screen's live subject
  // binding. Tests that delete the row underneath the open screen own a
  // controller here, exactly as a live Drift watch would emit, without leaving
  // a pending timer behind on dispose.
  Stream<Todo?>? todoStream,
}) {
  final router = GoRouter(
    initialLocation: '/active',
    routes: [
      GoRoute(path: '/active', builder: (_, _) => const ActiveFocusScreen()),
      GoRoute(
        path: '/focus',
        builder: (_, _) => const Scaffold(body: Text('focus-home')),
      ),
    ],
  );

  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      focusModeProvider.overrideWith(() => ActiveFocusModeNotifier(todo.id)),
      sprintTimerProvider
          .overrideWith(sprintTimer ?? IdleSprintTimerNotifier.new),
      taskDetailTodoProvider(todo.id)
          .overrideWith((_) => todoStream ?? Stream.value(todo)),
      activeSessionTasksProvider.overrideWith((_) => Stream.value([todo])),
      // Mandatory, not a nicety: `_onComplete` reads this provider's future,
      // and an un-overridden read reaches a live Drift `watch()` from a widget
      // test — which never delivers its first event and hangs the run for its
      // full ten-minute timeout rather than failing (docs/TESTING.md
      // § Frontend). `Stream.value` is the documented override shape.
      activeSessionSettlementsProvider.overrideWith(
        (_) => Stream.value(const <String, SessionSettlement>{}),
      ),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

/// [ActiveFocusScreen]'s sprint ring runs a continuously-repeating pulse
/// animation, so `pumpAndSettle` never settles while the screen is mounted.
/// Advance a bounded number of real frames instead, draining the real event
/// queue between frames so the drift writes each verdict performs land.
Future<void> pumpFocusFrames(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => pumpEventQueue(times: 2));
    await tester.pump(const Duration(milliseconds: 60));
  }
}
