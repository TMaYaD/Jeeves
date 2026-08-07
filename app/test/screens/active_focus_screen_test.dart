/// Tests for [ActiveFocusScreen]'s Done → re-clarify flow (issue #469).
///
/// Two layers:
///
/// * **Widget tests** drive the real screen over a real [GtdDatabase] to pin
///   the integration up to the point that is drivable under the test binding:
///   Done completes the current *Action* (not the Outcome) and floats
///   [ReclarifyPromptSheet] without a premature redirect, and each verdict (or
///   dismissal) lands the right write on the real Outcome. The tail of
///   `_onComplete` awaits `activeSessionTasksProvider.future` — a Riverpod
///   stream-provider future that only resolves on the real event loop and
///   cannot be advanced past by a fake-clock `pump` (the reason the screen was
///   historically untested), so the post-verdict *navigation + snackbar* is not
///   asserted here.
/// * **Unit tests** cover that snackbar's message decision directly via the
///   extracted [focusAdvanceMessage], which is where folded requirement #2
///   lives: "All done for today!" is claimed only on a genuine achieved verdict.
///
/// [ActiveFocusScreen] refreshes a persistent focus notification through
/// `NotificationService.instance` (a static singleton, not a provider) in an
/// initState post-frame callback, so a no-op notification platform is
/// registered below — see [_FakeNotificationsPlatform].
library;

import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show FlutterLocalNotificationsPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/focus_session_provider.dart';
import 'package:jeeves/providers/sprint_timer_provider.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/screens/active_focus_screen.dart';
import 'package:jeeves/widgets/app_title_bar/app_title_bar.dart';
import 'package:jeeves/widgets/process_to_handlers.dart' show ProcessAction;
import 'package:jeeves/widgets/reclarify_prompt_sheet.dart';

import '../test_helpers.dart';

const _userId = 'local';

const _notificationsChannel =
    MethodChannel('dexterous.com/flutter/local_notifications');

/// A stand-in [FlutterLocalNotificationsPlatform] that is deliberately *not*
/// the Android/iOS concrete plugin. `ActiveFocusScreen` refreshes its
/// persistent notification through `NotificationService.instance`, whose plugin
/// resolves the platform-specific implementation before touching the method
/// channel — and that resolution reads `FlutterLocalNotificationsPlatform.instance`,
/// a late static that is never initialised in tests. Registering this fake both
/// satisfies that late field and, because it is not the Android plugin type,
/// makes `resolvePlatformSpecificImplementation<Android…>()` return null so
/// `show`/`cancel` become no-ops. The default constructor forwards the real
/// platform-interface token, so the `instance=` setter's token check passes
/// without a mock mixin.
class _FakeNotificationsPlatform extends FlutterLocalNotificationsPlatform {}

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

/// Focus-mode notifier pinned active on [_todoId], with a DB-free [endFocus]
/// so the session close doesn't need a real FocusSession row.
class _ActiveFocusModeNotifier extends FocusModeNotifier {
  _ActiveFocusModeNotifier(this._todoId);
  final String _todoId;

  @override
  FocusModeState build() =>
      FocusModeState(activeTodoId: _todoId, sessionStart: DateTime.now());

  @override
  Future<void> endFocus() async {
    state = const FocusModeState();
  }
}

/// Sprint timer stubbed idle — skips `_restoreFromPrefs()` and the sprint
/// start/stop side effects (haptics, notifications, DB time-log reads).
class _IdleSprintTimerNotifier extends SprintTimerNotifier {
  @override
  SprintTimerState build() => const SprintTimerState();

  @override
  Future<void> startSprint(Todo task) async {}

  @override
  Future<void> stopSprint() async {}
}

/// Sprint timer whose [stopSprint] blocks on a caller-controlled gate, so a
/// test can observe whether `_onComplete` *awaits* the stop (the sheet must not
/// float, and the Action must not yet be completed, until the gate opens).
class _GatedSprintTimerNotifier extends SprintTimerNotifier {
  _GatedSprintTimerNotifier(this._gate);
  final Completer<void> _gate;

  @override
  SprintTimerState build() => const SprintTimerState();

  @override
  Future<void> startSprint(Todo task) async {}

  @override
  Future<void> stopSprint() async {
    await _gate.future;
  }
}

Future<Todo> _insertTodo(
  GtdDatabase db, {
  required String id,
  String title = 'Ship the thing',
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value(title),
        clarified: const Value(true),
        intent: const Value('next'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  return (await db.todoDao.getTodo(id))!;
}

/// Builds the router harness rendering [ActiveFocusScreen] at `/active`, with a
/// placeholder `focus-home` at `/focus`.
Widget _harness(
  GtdDatabase db, {
  required Todo todo,
  SprintTimerNotifier Function()? sprintTimer,
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
      focusModeProvider.overrideWith(() => _ActiveFocusModeNotifier(todo.id)),
      sprintTimerProvider
          .overrideWith(sprintTimer ?? _IdleSprintTimerNotifier.new),
      taskDetailTodoProvider(todo.id).overrideWith((_) => Stream.value(todo)),
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
Future<void> _pumpFrames(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => pumpEventQueue(times: 2));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _tapDone(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Done'));
  await _pumpFrames(tester);
}

void main() {
  setUpAll(configureSqliteForTests);

  group('ActiveFocusScreen — Done floats the re-clarify prompt', () {
    late GtdDatabase db;
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterLocalNotificationsPlatform.instance = _FakeNotificationsPlatform();
      TestWidgetsFlutterBinding.ensureInitialized()
          .defaultBinaryMessenger
          .setMockMethodCallHandler(_notificationsChannel, (_) async => null);
      db = _openInMemory();
    });
    tearDown(() async {
      TestWidgetsFlutterBinding.ensureInitialized()
          .defaultBinaryMessenger
          .setMockMethodCallHandler(_notificationsChannel, null);
      await db.close();
    });

    testWidgets('pins the global capture action in the bar (#458)',
        (tester) async {
      final todo = await _insertTodo(db, id: 'o1');
      await seedCurrentAction(db, outcomeId: 'o1', text: 'do it', userId: _userId);

      await tester.pumpWidget(_harness(db, todo: todo));
      await _pumpFrames(tester);

      // Direct find.byKey: the pinned slot never overflows.
      expect(find.byKey(const Key('capture_action')), findsOneWidget);
    });

    // This test covers the screen-specific wiring: Done runs
    // completeCurrentAction and floats the sheet without a premature redirect.
    // The four verdicts' own writes (achieved → Completion, defer → maybe,
    // dismiss → nothing, etc.) are exhaustively covered in
    // reclarify_prompt_sheet_test.dart over the same ProcessToHandlers /
    // OutcomeSubject the sheet embeds; re-driving them through the full screen
    // (modal route + the sprint ring's perpetual animation + a Riverpod
    // stream-provider future that does not resolve under a fake-clock pump) adds
    // only fragility, not coverage.
    testWidgets(
        'Done completes the current Action (not the Outcome), floats the '
        'prompt without redirecting, and leaves the Outcome needing review '
        '(AC1/AC2/AC4)', (tester) async {
      final todo = await _insertTodo(db, id: 'o1');
      await seedCurrentAction(db, outcomeId: 'o1', text: 'do it', userId: _userId);

      await tester.pumpWidget(_harness(db, todo: todo));
      await _pumpFrames(tester);
      await _tapDone(tester);

      // The re-clarify prompt is floating, and the session is still active — no
      // premature redirect to /focus underneath the sheet.
      expect(find.byType(ReclarifyPromptSheet), findsOneWidget);
      expect(find.text('Action complete'), findsOneWidget);
      expect(find.text('Outcome achieved'), findsOneWidget);
      expect(find.text('focus-home'), findsNothing);

      // The current Action was terminated (role='done'), leaving the Outcome
      // Actionless; the Outcome itself is NOT achieved and NOT re-clarified.
      expect(await db.actionDao.getCurrentAction('o1'), isNull);
      final row = await db.todoDao.getTodo('o1');
      expect(row?.doneAt, isNull);
      expect(row?.lastClarifiedAt, isNull);

      // Actionless + un-stamped ⇒ surfaces in the next DPR's review step. If the
      // user dismisses the prompt (writing nothing — see the sheet test), the
      // Outcome simply stays here for review (AC4).
      final needsReview = await db.todoDao.getNeedsReview();
      expect(needsReview.map((t) => t.id), contains('o1'));
    });

    // Guards the ordering that the `.ignore()` → `await` fix restores:
    // stopSprint() persists sprint history before it returns, so `_onComplete`
    // must await it. With a fire-and-forget stop, the Action completion and the
    // sheet would race ahead of the persistence; with the await, neither the
    // Action-completion write nor the sheet may appear until the stop resolves.
    testWidgets(
        'Done awaits stopSprint before completing the Action and floating '
        'the prompt', (tester) async {
      final todo = await _insertTodo(db, id: 'o2');
      await seedCurrentAction(db, outcomeId: 'o2', text: 'do it', userId: _userId);

      final gate = Completer<void>();
      await tester.pumpWidget(
        _harness(db, todo: todo, sprintTimer: () => _GatedSprintTimerNotifier(gate)),
      );
      await _pumpFrames(tester);
      await _tapDone(tester);

      // stopSprint is still blocked: the Action is NOT yet completed and the
      // sheet has NOT floated — proof that `_onComplete` awaits the stop.
      expect(await db.actionDao.getCurrentAction('o2'), isNotNull,
          reason: 'completeCurrentAction must not run before stopSprint resolves');
      expect(find.byType(ReclarifyPromptSheet), findsNothing);

      // Release the stop; the flow resumes in order — Action completes, then the
      // sheet floats.
      gate.complete();
      await _pumpFrames(tester);

      expect(await db.actionDao.getCurrentAction('o2'), isNull);
      expect(find.byType(ReclarifyPromptSheet), findsOneWidget);
      expect(find.text('focus-home'), findsNothing);
    });
  });

  group('ActiveFocusScreen — title bar (ADR-0021)', () {
    late GtdDatabase db;
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterLocalNotificationsPlatform.instance = _FakeNotificationsPlatform();
      TestWidgetsFlutterBinding.ensureInitialized()
          .defaultBinaryMessenger
          .setMockMethodCallHandler(_notificationsChannel, (_) async => null);
      db = _openInMemory();
    });
    tearDown(() async {
      TestWidgetsFlutterBinding.ensureInitialized()
          .defaultBinaryMessenger
          .setMockMethodCallHandler(_notificationsChannel, null);
      await db.close();
    });

    // The bar's title is a pure function of the active task (ADR-0021) — the
    // screen no longer hand-rolls its own header. And leaving focus is a
    // router `go` back to the execution home, not a `Navigator.pop` (this
    // route was reached by `go`, so a pop would have nothing productive to
    // pop): the screen overrides the bar's default back behaviour with
    // `onLeadingPressed: () => context.go('/focus')`. Both are reachable at
    // pump time — this test does not touch the never-resolving Done tail
    // (see the file doc comment).
    testWidgets(
        "the bar's title is the active task's title, and the leading action "
        'routes to /focus via context.go (not Navigator.pop)', (tester) async {
      final todo = await _insertTodo(db, id: 'o3', title: 'Write the ADR');
      await seedCurrentAction(db, outcomeId: 'o3', text: 'do it', userId: _userId);

      await tester.pumpWidget(_harness(db, todo: todo));
      await _pumpFrames(tester);

      final bar = tester.widget<AppTitleBar>(find.byType(AppTitleBar));
      expect(bar.title, 'Write the ADR');

      await tester.tap(find.byKey(appTitleBarLeadingKey));
      await _pumpFrames(tester);

      // Landed on the /focus route registered in the harness — proof the
      // leading action is a `context.go('/focus')`, not a pop (there is
      // nothing above '/active' in this harness's Navigator to pop to).
      expect(find.text('focus-home'), findsOneWidget);
    });
  });

  group('focusNextTask — a Settled task is not offered as next up (#693 AC2)',
      () {
    Todo todo(String id, {String? doneAt}) => Todo(
          id: id,
          title: 'Task $id',
          createdAt: DateTime.now(),
          doneAt: doneAt,
          clarified: true,
          intent: 'next',
          userId: _userId,
        );

    test('picks the first task that is neither the completed one nor done', () {
      expect(
        focusNextTask(
          sessionTasks: [todo('a'), todo('b'), todo('c')],
          completedTodoId: 'a',
          settlements: const {},
        )?.id,
        'b',
      );
    });

    test('skips a task Settled to a non-done verdict', () {
      expect(
        focusNextTask(
          sessionTasks: [todo('a'), todo('b'), todo('c')],
          completedTodoId: 'a',
          settlements: const {'b': SessionSettlement.next},
        )?.id,
        'c',
        reason: 'b was resolved this session — handing it back re-presents '
            'work the user is done with',
      );
    });

    test('every remaining task Settled yields no next task', () {
      expect(
        focusNextTask(
          sessionTasks: [todo('a'), todo('b'), todo('c')],
          completedTodoId: 'a',
          settlements: const {
            'b': SessionSettlement.waitingFor,
            'c': SessionSettlement.someday,
          },
        ),
        isNull,
      );
    });

    test('an unsettled task is still offered even after other tasks settle',
        () {
      expect(
        focusNextTask(
          sessionTasks: [todo('a'), todo('b'), todo('c')],
          completedTodoId: 'a',
          settlements: const {'b': SessionSettlement.done},
        )?.id,
        'c',
      );
    });
  });

  group('focusAdvanceMessage — "All done" only on a genuine achieved verdict',
      () {
    Todo todo(String id, String title) => Todo(
          id: id,
          title: title,
          createdAt: DateTime.now(),
          clarified: true,
          intent: 'next',
          userId: _userId,
        );

    test('a remaining task always yields the "Next up" advance message', () {
      // Even an achieved verdict advances to the next task, not "All done".
      expect(
        focusAdvanceMessage(
          nextTask: todo('t2', 'Second'),
          verdict: ProcessAction.done,
        ),
        'Done! Next up: Second',
      );
    });

    test('achieved + no remaining task claims "All done for today!"', () {
      expect(
        focusAdvanceMessage(nextTask: null, verdict: ProcessAction.done),
        'All done for today!',
      );
    });

    test('a "More to do" verdict never claims "All done" (folded req #2)', () {
      // Both a real and a blank "More to do" save resolve as nextActionDialog,
      // which is NOT an achievement.
      expect(
        focusAdvanceMessage(
          nextTask: null,
          verdict: ProcessAction.nextActionDialog,
        ),
        'Sprint logged — nothing else planned.',
      );
    });

    test('waiting / defer / dismiss never claim "All done"', () {
      for (final verdict in <ProcessAction?>[
        ProcessAction.waitingFor,
        ProcessAction.someday,
        null,
      ]) {
        expect(
          focusAdvanceMessage(nextTask: null, verdict: verdict),
          'Sprint logged — nothing else planned.',
          reason: 'verdict $verdict is not an achievement',
        );
      }
    });
  });
}
