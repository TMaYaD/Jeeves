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
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show FlutterLocalNotificationsPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/sprint_timer_provider.dart';
import 'package:jeeves/screens/active_focus_screen.dart';
import 'package:jeeves/sync/collection_codecs.dart' show todosCollection;
import 'package:jeeves/sync/domain_op_capture.dart'
    show RecordingDomainOpCapture;
import 'package:jeeves/widgets/app_title_bar/app_title_bar.dart';
import 'package:jeeves/widgets/process_to_handlers.dart' show ProcessAction;
import 'package:jeeves/widgets/reclarify_prompt_sheet.dart';

import '../helpers/active_focus_harness.dart';
import '../test_helpers.dart';

// The harness pieces below are shared with the integration-tier journey test
// (issue #723) — the real definitions live in `../helpers/active_focus_harness.dart`
// and these thin aliases keep this file's body unchanged.
const _userId = focusUserId;
const _notificationsChannel = focusNotificationsChannel;
typedef _FakeNotificationsPlatform = FakeNotificationsPlatform;
GtdDatabase _openInMemory() => openFocusInMemory();

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
  String? notes,
}) =>
    insertFocusTodo(db, id: id, title: title, notes: notes);

Widget _harness(
  GtdDatabase db, {
  required Todo todo,
  SprintTimerNotifier Function()? sprintTimer,
  Stream<Todo?>? todoStream,
}) =>
    focusHarness(db, todo: todo, sprintTimer: sprintTimer, todoStream: todoStream);

Future<void> _pumpFrames(WidgetTester tester, [int n = 8]) =>
    pumpFocusFrames(tester, n);

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

  group('ActiveFocusScreen — title bar', () {
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

    // The bar's title is a pure function of the active task — the
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
    const achievedAt = '2026-05-01T10:00:00.000Z';
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

    test('skips an already-achieved task, with no help from the map', () {
      expect(
        focusNextTask(
          sessionTasks: [todo('a'), todo('b', doneAt: achievedAt), todo('c')],
          completedTodoId: 'a',
          settlements: const {},
        )?.id,
        'c',
        reason: 'the doneAt guard has to hold on its own — the settlement map '
            'is empty until its stream emits',
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

  // ---------------------------------------------------------------------------
  // A pending notes edit at teardown (issue #533).
  //
  // The notes page saves on focus loss and on a 500ms debounce; `dispose()`
  // used to cancel the debounce and flush nothing, so leaving the screen inside
  // that window — or with the field still focused — dropped the edit silently.
  // The backstop is the same shape `TaskDetailScreen` and `ClarifyCard` keep.
  //
  // The row is read **raw** rather than through `TodoDao.getTodo`, whose D2
  // projection COALESCEs the current Action's values over these columns
  // (NOTES.md 2026-07-26).
  // ---------------------------------------------------------------------------
  group('ActiveFocusScreen — a pending notes edit at teardown (#533)', () {
    late GtdDatabase db;
    late RecordingDomainOpCapture capture;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterLocalNotificationsPlatform.instance = _FakeNotificationsPlatform();
      TestWidgetsFlutterBinding.ensureInitialized()
          .defaultBinaryMessenger
          .setMockMethodCallHandler(_notificationsChannel, (_) async => null);
      capture = RecordingDomainOpCapture();
      db = GtdDatabase(NativeDatabase.memory(), opCapture: capture);
    });
    tearDown(() async {
      TestWidgetsFlutterBinding.ensureInitialized()
          .defaultBinaryMessenger
          .setMockMethodCallHandler(_notificationsChannel, null);
      await db.close();
    });

    Future<Map<String, Object?>> rawRow(String id) async => (await db
            .customSelect(
              'SELECT notes, updated_at FROM todos WHERE id = ?',
              variables: [Variable.withString(id)],
            )
            .getSingle())
        .data;

    /// Moves the carousel to the notes page and opens its editor.
    ///
    /// The page change is driven through the [PageController] rather than a
    /// drag: the sprint ring owns a tap target at the PageView's centre, which
    /// is exactly where `tester.drag` starts its gesture.
    Future<void> openNotesEditor(WidgetTester tester) async {
      tester.widget<PageView>(find.byType(PageView)).controller!.jumpToPage(1);
      await _pumpFrames(tester, 2);
      await tester.tap(find.byIcon(Icons.edit_outlined));
      // Past the 50ms delayed `requestFocus` the page schedules.
      await _pumpFrames(tester, 2);
      expect(find.byType(TextField), findsOneWidget,
          reason: 'the notes editor must actually be open, or the teardown '
              'assertions below are vacuous');
    }

    /// Tears the whole tree down with the field still focused and the debounce
    /// still pending, then lets the fire-and-forget flush reach the database.
    Future<void> unmountWhileFocused(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => pumpEventQueue());
    }

    testWidgets(
        'a notes edit still saves when the page is torn down with the field '
        'focused', (tester) async {
      final todo = await _insertTodo(db, id: 'o1');
      await tester.pumpWidget(_harness(db, todo: todo));
      await _pumpFrames(tester);
      await openNotesEditor(tester);

      await tester.enterText(find.byType(TextField), 'Ask the barista');
      await unmountWhileFocused(tester);

      expect((await rawRow('o1'))['notes'], 'Ask the barista');
    });

    testWidgets('a notes edit typed inside the 500ms debounce window survives '
        'teardown', (tester) async {
      final todo = await _insertTodo(db, id: 'o1');
      await tester.pumpWidget(_harness(db, todo: todo));
      await _pumpFrames(tester);
      await openNotesEditor(tester);

      await tester.enterText(find.byType(TextField), 'Half a thought');
      // Well inside the debounce: the timer `dispose()` cancels has not fired,
      // so the flush is the only thing that can save this.
      await tester.pump(const Duration(milliseconds: 200));
      await unmountWhileFocused(tester);

      expect((await rawRow('o1'))['notes'], 'Half a thought');
    });

    // The other side of the guard: an unconditional flush would stamp
    // `updated_at` and `last_clarified_at` and author a sync op every time the
    // user left the focus screen without touching the notes.
    testWidgets('a clean teardown issues no write', (tester) async {
      final todo = await _insertTodo(db, id: 'o1', notes: 'Ask the barista');
      final seededUpdatedAt = (await rawRow('o1'))['updated_at'];
      await tester.pumpWidget(_harness(db, todo: todo));
      await _pumpFrames(tester);
      await openNotesEditor(tester);
      capture.clear();

      await unmountWhileFocused(tester);

      final row = await rawRow('o1');
      expect(row['notes'], 'Ask the barista');
      expect(row['updated_at'], seededUpdatedAt);
      expect(capture.forCollection(todosCollection), isEmpty);
    });

    testWidgets('a failing flush is logged rather than thrown into teardown',
        (tester) async {
      final todo = await _insertTodo(db, id: 'o1');
      await tester.pumpWidget(_harness(db, todo: todo));
      await _pumpFrames(tester);
      await openNotesEditor(tester);
      await tester.enterText(find.byType(TextField), 'Ask the barista');

      // Closing the database is the one way to fail this write from outside the
      // page: it is issued after `dispose()` has already run.
      await db.close();
      await unmountWhileFocused(tester);

      expect(tester.takeException(), isNull);
    });

    // Two things at once, because on this screen they are the same event.
    //
    // 1. The mirror of `task_detail_screen_test`'s subject-missing case: a
    //    write must not outlive its subject (#446 / #447). It matters *more*
    //    here — the screen's null branch swaps the body out and routes away, so
    //    the notes page is genuinely torn down at the moment the row goes, on
    //    the ordinary path rather than a rare one.
    // 2. The proof that Riverpod delivers the page's own `ref.listen` callback
    //    before the parent's `ref.watch` rebuild unmounts it. If that ordering
    //    did not hold, the latch would still be false here and the flush would
    //    land on the deleted row — which is exactly what this asserts against.
    testWidgets('a row that goes missing under the open screen is never '
        'written to, and authors no op', (tester) async {
      final todo = await _insertTodo(db, id: 'o1');
      final seededUpdatedAt = (await rawRow('o1'))['updated_at'];
      final feed = StreamController<Todo?>.broadcast();
      addTearDown(feed.close);

      await tester
          .pumpWidget(_harness(db, todo: todo, todoStream: feed.stream));
      feed.add(todo);
      await _pumpFrames(tester);
      await openNotesEditor(tester);
      await tester.enterText(find.byType(TextField), 'Ask the barista');

      // The row leaves local storage under the open screen. The provider
      // override decouples the stream from the row, so the row is still there
      // to prove the negative.
      capture.clear();
      feed.add(null);
      await _pumpFrames(tester);
      await unmountWhileFocused(tester);

      final row = await rawRow('o1');
      expect(row['notes'], isNull);
      expect(row['updated_at'], seededUpdatedAt);
      // The op-log assertion is the one that survives a future DAO that upserts.
      expect(capture.forCollection(todosCollection), isEmpty);
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
