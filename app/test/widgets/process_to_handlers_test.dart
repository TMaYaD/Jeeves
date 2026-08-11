/// Widget tests for [ProcessToHandlers] (issue #276).
///
/// Drives a real [TodoDao] over an in-memory [GtdDatabase] so the per-action
/// DAO writes can be asserted directly on the resulting Todo state.
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/action_draft.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/tags_provider.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/services/clarification_service.dart';
import 'package:jeeves/widgets/app_title_bar/app_title_bar.dart';
import 'package:jeeves/widgets/clarify_card.dart';
import 'package:jeeves/widgets/next_action_dialog.dart';
import 'package:jeeves/widgets/process_to_handlers.dart';

import '../helpers/app_title_bar_test_helpers.dart';

import '../test_helpers.dart';

const _userId = 'local';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

Future<Todo> _insertTodo(
  GtdDatabase db, {
  required String id,
  String title = 'Task',
  bool clarified = true,
  String intent = 'next',
  String? doneAt,
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value(title),
        clarified: Value(clarified),
        intent: Value(intent),
        doneAt: doneAt != null ? Value(doneAt) : const Value.absent(),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  return (await db.todoDao.getTodo(id))!;
}

Future<String> _insertPersonTag(
  GtdDatabase db, {
  required String id,
  required String name,
}) async {
  await db.tagDao.upsertTag(TagsCompanion(
    id: Value(id),
    name: Value(name),
    type: const Value('person'),
    userId: const Value(_userId),
  ));
  return id;
}

/// A [ClarificationService] whose in-place routing write always fails.
class _FailingClarificationService extends DaoClarificationService {
  _FailingClarificationService(super.db);

  @override
  Future<void> clarifyToOutcome(
    String id, {
    required RoutingKind to,
    String? actionText,
    Set<String>? personTagIds,
    String? userId,
  }) =>
      Future<void>.error(StateError('write failed'));

  // Discarding a Capture is a different method on a different write path, so
  // failing `clarifyToOutcome` alone would leave it uncovered.
  @override
  Future<void> discardCapture(String captureId, {DateTime? now}) =>
      Future<void>.error(StateError('write failed'));
}

/// A [ClarificationService] whose subject disappeared between render and
/// commit — the snapshot-staleness case [_subjectExists] guards.
class _VanishedClarificationService extends DaoClarificationService {
  _VanishedClarificationService(super.db);

  @override
  Future<bool> exists(String id) async => false;

  // `_subjectExists` dispatches on subject kind, so the Capture branch needs
  // its own stub — overriding `exists` alone leaves it live.
  @override
  Future<bool> captureExists(String captureId) async => false;
}

Widget _harness(
  GtdDatabase db, {
  required Todo todo,
  Set<ProcessAction> include = const {},
  Set<ProcessAction> except = const {},
  Set<ProcessAction> disabled = const {},
  Map<ProcessAction, String> labels = const {},
  ProcessAction? lastAction,
  Future<void> Function(ProcessAction)? onAfterRoute,
  List<Tag> personTags = const [],
  ClarificationService? clarificationService,
  String? currentActionText,
}) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      if (clarificationService != null)
        clarificationServiceProvider.overrideWithValue(clarificationService),
      // Use a single-value stream so drift's StreamQueryStore (which leaves
      // a pending timer behind on dispose) is not subscribed to in tests.
      personTagsProvider.overrideWith((ref) => Stream.value(personTags)),
      // The reclarify sub-flow renders a [ClarifyCard] which watches these
      // providers (todo + tag list + the pickers' own tag catalogues);
      // static streams avoid drift's StreamQuery timer.
      taskDetailTodoProvider(todo.id).overrideWith((_) => Stream.value(todo)),
      taskTagsProvider(todo.id)
          .overrideWith((_) => Stream.value(const <Tag>[])),
      contextTagsProvider.overrideWith((_) => Stream.value(const <Tag>[])),
      projectTagsProvider.overrideWith((_) => Stream.value(const <Tag>[])),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            ProcessToHandlers(
              subject: OutcomeSubject(
                todo,
                currentActionText: currentActionText,
              ),
              include: include,
              except: except,
              disabled: disabled,
              labels: labels,
              lastAction: lastAction,
              onAfterRoute: onAfterRoute,
            ),
          ],
        ),
      ),
    ),
  );
}

/// Same harness, over a [CaptureSubject] — the shape whose `trash` action is
/// the zero-Outcome discard rather than a move to the Trash List.
Widget _captureHarness(
  GtdDatabase db, {
  required Capture capture,
  Future<void> Function(ProcessAction)? onAfterRoute,
  ClarificationService? clarificationService,
  List<Tag> personTags = const [],
}) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      if (clarificationService != null)
        clarificationServiceProvider.overrideWithValue(clarificationService),
      personTagsProvider.overrideWith((ref) => Stream.value(personTags)),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            ProcessToHandlers(
              subject: CaptureSubject(
                capture: capture,
                draft: () => ClarifyDraft(title: capture.title),
              ),
              except: const {ProcessAction.nextActionDialog},
              onAfterRoute: onAfterRoute,
            ),
          ],
        ),
      ),
    ),
  );
}

Future<Capture> _insertCapture(
  GtdDatabase db, {
  required String id,
  String title = 'Fragment',
}) async {
  final now = DateTime.now();
  await db.captureDao.insertCapture(CapturesCompanion(
    id: Value(id),
    title: Value(title),
    captureSource: const Value('manual'),
    userId: const Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
  return (await db.captureDao.getCapture(id))!;
}

Tag _personTag(String id, String name) => Tag(
      id: id,
      name: name,
      type: 'person',
      userId: _userId,
    );

void main() {
  setUpAll(configureSqliteForTests);

  group('ProcessToHandlers — render', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets('default render shows Next, Waiting For, Someday, Done, Trash',
        (tester) async {
      final todo = await _insertTodo(db, id: 't1');
      await tester.pumpWidget(_harness(db, todo: todo));

      expect(find.text('Next Action'), findsOneWidget);
      expect(find.text('Waiting For'), findsOneWidget);
      expect(find.text('Someday'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Trash'), findsOneWidget);
      // Hidden by default.
      expect(find.text('Keep'), findsNothing);
    });

    testWidgets('include adds Keep with default label "Keep"', (tester) async {
      final todo = await _insertTodo(db, id: 't2');
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        include: const {ProcessAction.keep},
      ));

      expect(find.text('Keep'), findsOneWidget);
    });

    testWidgets('Re-clarify… is hidden by default; include surfaces it',
        (tester) async {
      final todo = await _insertTodo(db, id: 'rc-render');
      await tester.pumpWidget(_harness(db, todo: todo));
      expect(find.text('Re-clarify…'), findsNothing);

      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        include: const {ProcessAction.reclarify},
      ));
      await tester.pump();
      expect(find.text('Re-clarify…'), findsOneWidget);
    });

    testWidgets('except hides specified default actions', (tester) async {
      final todo = await _insertTodo(db, id: 't3');
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        except: const {ProcessAction.done, ProcessAction.waitingFor},
      ));

      expect(find.text('Done'), findsNothing);
      expect(find.text('Waiting For'), findsNothing);
      expect(find.text('Next Action'), findsOneWidget);
      expect(find.text('Someday'), findsOneWidget);
      expect(find.text('Trash'), findsOneWidget);
    });

    testWidgets('labels override button text', (tester) async {
      final todo = await _insertTodo(db, id: 't4');
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        labels: const {
          ProcessAction.next: 'Plan it',
          ProcessAction.done: 'Did it',
        },
      ));

      expect(find.text('Plan it'), findsOneWidget);
      expect(find.text('Did it'), findsOneWidget);
      expect(find.text('Next Action'), findsNothing);
      expect(find.text('Done'), findsNothing);
    });

    testWidgets(
        'disabled renders buttons with onPressed=null; trash still fires',
        (tester) async {
      final todo = await _insertTodo(db, id: 't5');
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        disabled: const {
          ProcessAction.next,
          ProcessAction.waitingFor,
          ProcessAction.someday,
          ProcessAction.done,
        },
      ));

      // Disabled → onPressed is null.
      final nextBtn = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('Next Action'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(nextBtn.onPressed, isNull);

      final trashBtn = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('Trash'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(trashBtn.onPressed, isNotNull);

      await tester.tap(find.text('Trash'));
      await tester.pumpAndSettle();
      final row = await db.todoDao.getTodo('t5');
      expect(row?.intent, 'trash');
    });

    testWidgets('lastAction highlights matching button', (tester) async {
      final todo = await _insertTodo(db, id: 't6');
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        lastAction: ProcessAction.someday,
      ));

      // The previously-selected affordance renders an extra check_circle
      // icon inside the button label. Find one matching the Someday button.
      final iconsInside = find.descendant(
        of: find.ancestor(
          of: find.text('Someday'),
          matching: find.byType(OutlinedButton),
        ),
        matching: find.byIcon(Icons.check_circle),
      );
      expect(iconsInside, findsOneWidget);
    });

    testWidgets('trash is labelled "Trash" on an Outcome', (tester) async {
      final todo = await _insertTodo(db, id: 't7');
      await tester.pumpWidget(_harness(db, todo: todo));

      // An Outcome routed to trash lands on the Trash List (`Intent = trash`),
      // so "Trash" names a real destination.
      expect(find.text('Trash'), findsOneWidget);
      expect(find.text('Discard Capture'), findsNothing);
    });

    testWidgets('trash is labelled "Discard Capture" on a Capture',
        (tester) async {
      final capture = await _insertCapture(db, id: 'c7');
      await tester.pumpWidget(_captureHarness(db, capture: capture));

      // A discarded Capture creates no Outcome, so it never reaches that
      // List. Naming it "Trash" would promise a destination it never arrives
      // at, and the verdict names its subject because it ends the *Capture*,
      // not one Outcome among several.
      expect(find.text('Discard Capture'), findsOneWidget);
      expect(find.text('Trash'), findsNothing);
    });
  });

  group('RoutingKindToProcessAction extension', () {
    test('maps every RoutingKind to its ProcessAction counterpart', () {
      expect(RoutingKind.nextAction.toProcessAction(), ProcessAction.next);
      expect(RoutingKind.waitingFor.toProcessAction(),
          ProcessAction.waitingFor);
      expect(RoutingKind.maybe.toProcessAction(), ProcessAction.someday);
      expect(RoutingKind.done.toProcessAction(), ProcessAction.done);
      expect(RoutingKind.trash.toProcessAction(), ProcessAction.trash);
    });
  });

  // `onAfterRoute` fires for every action this bar handles, including the ones
  // that deliberately leave a Capture in the Inbox. A surface holding
  // something on the Capture's behalf — [ClarifyCard]'s retained draft
  // (ADR-0023) — reads this to tell the two apart, so getting an entry wrong
  // here is the difference between a spent draft lingering and the user's
  // typing being thrown away on an item they have not finished clarifying.
  group('ProcessActionEndsCaptureClarification extension', () {
    test('the routing destinations and the n-m verdict end the clarify act',
        () {
      // Each of these reaches `_commit` (or `completeCaptureClarification`)
      // unconditionally once the Capture still exists, so the row is either
      // stamped or discarded by the time the hook runs.
      for (final action in const [
        ProcessAction.next,
        ProcessAction.waitingFor,
        ProcessAction.someday,
        ProcessAction.done,
        ProcessAction.trash,
        ProcessAction.completeCapture,
        // The dialog modifier joined them with #689, which is what first
        // enabled it on a Capture surface. Whenever it notifies, a route has
        // landed: the commit is unconditional, and the one arm that writes
        // nothing (a blank phrase over a blank title) returns without
        // notifying at all.
        ProcessAction.nextActionDialog,
      ]) {
        expect(action.endsCaptureClarification, isTrue, reason: '$action');
      }
    });

    test('keep and reclarify do not', () {
      // `keep` on a Capture is an explicit no-op — the whole point is that the
      // item stays in the Inbox with `clarified_at` NULL. `reclarify` throws
      // on a Capture, so it can never report one.
      for (final action in const [
        ProcessAction.keep,
        ProcessAction.reclarify,
      ]) {
        expect(action.endsCaptureClarification, isFalse, reason: '$action');
      }
    });

    test('every ProcessAction is classified', () {
      // The switch is exhaustive, so a new action fails to compile rather than
      // defaulting into either answer — this pins that the enum and the two
      // lists above stay in step.
      expect(ProcessAction.values.length, 9);
    });
  });

  group('ProcessToHandlers — keep', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets(
        'keep stamps lastClarifiedAt; does not change intent or doneAt',
        (tester) async {
      final todo = await _insertTodo(db, id: 'k1', intent: 'next');
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        include: const {ProcessAction.keep},
      ));

      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('k1');
      expect(row?.lastClarifiedAt, isNotNull);
      expect(row?.intent, 'next');
      expect(row?.doneAt, isNull);
    });
  });

  group('ProcessToHandlers — cleanup behavior (doneAt)', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets('Next clears doneAt on a previously-done todo',
        (tester) async {
      // Seed a done todo via applyRouting so doneAt is correctly set.
      await _insertTodo(db, id: 'd1');
      await db.todoDao.applyRouting('d1', to: RoutingKind.done);
      final todo = (await db.todoDao.getTodo('d1'))!;
      expect(todo.doneAt, isNotNull);

      // Plain-next behaviour: except the default-on dialog modifier so the
      // tap routes immediately without opening NextActionDialog.
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        except: const {ProcessAction.nextActionDialog},
      ));
      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('d1');
      expect(row?.doneAt, isNull);
      expect(row?.intent, 'next');
    });
  });

  group('ProcessToHandlers — waitingFor sub-flow', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets('cancelling the picker does NOT route or fire onAfterRoute',
        (tester) async {
      final todo = await _insertTodo(db, id: 'wf1');
      await _insertPersonTag(db, id: 'alice', name: 'Alice');
      var afterCount = 0;
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        personTags: [_personTag('alice', 'Alice')],
        onAfterRoute: (_) async => afterCount++,
      ));

      await tester.tap(find.text('Waiting For'));
      await tester.pumpAndSettle();
      // Picker open — tap Cancel.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('wf1');
      // Routing did not happen — clarified flag was already true on insert
      // but lastClarifiedAt should NOT have been bumped.
      expect(row?.lastClarifiedAt, isNull);
      expect(row?.intent, 'next',
          reason: 'cancelling the picker must not mutate intent');
      expect(afterCount, 0);
    });

    testWidgets('confirming the picker routes once and fires onAfterRoute',
        (tester) async {
      final todo = await _insertTodo(db, id: 'wf2');
      await _insertPersonTag(db, id: 'alice', name: 'Alice');
      ProcessAction? afterArg;
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        personTags: [_personTag('alice', 'Alice')],
        onAfterRoute: (action) async => afterArg = action,
      ));

      await tester.tap(find.text('Waiting For'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();
      // Picker confirm: FilledButton labelled "Done" — disambiguate from
      // the route bar's OutlinedButton "Done" by widget type.
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pumpAndSettle();

      final tagIds = await db.todoDao.getPersonTagIdsForTodo('wf2');
      expect(tagIds, contains('alice'));
      final row = await db.todoDao.getTodo('wf2');
      expect(row?.intent, 'next');
      expect(row?.lastClarifiedAt, isNotNull);
      expect(afterArg, ProcessAction.waitingFor);
    });

    testWidgets('a subject that vanished mid-pick leaves no person tags behind',
        (tester) async {
      // The picker used to write its tag diff before the existence check, so
      // confirming into a row that had since been deleted left orphan
      // person-tag mutations with no routing write. The selection now comes
      // back as a value and nothing is written until the check passes.
      final todo = await _insertTodo(db, id: 'wf3');
      await _insertPersonTag(db, id: 'alice', name: 'Alice');
      var afterCount = 0;
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        personTags: [_personTag('alice', 'Alice')],
        clarificationService: _VanishedClarificationService(db),
        onAfterRoute: (_) async => afterCount++,
      ));

      await tester.tap(find.text('Waiting For'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pumpAndSettle();

      expect(await db.todoDao.getPersonTagIdsForTodo('wf3'), isEmpty);
      final row = await db.todoDao.getTodo('wf3');
      expect(row?.lastClarifiedAt, isNull);
      expect(afterCount, 0);
    });

    testWidgets('a Capture that vanished mid-pick carves no Outcome',
        (tester) async {
      // The Capture branch of `_subjectExists` routes through `captureExists`,
      // so it needs its own coverage — the Outcome test above cannot reach it.
      final capture = await _insertCapture(db, id: 'wfc3');
      await _insertPersonTag(db, id: 'alice', name: 'Alice');
      var afterCount = 0;
      await tester.pumpWidget(_captureHarness(
        db,
        capture: capture,
        personTags: [_personTag('alice', 'Alice')],
        clarificationService: _VanishedClarificationService(db),
        onAfterRoute: (_) async => afterCount++,
      ));

      await tester.tap(find.text('Waiting For'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pumpAndSettle();

      expect(await db.select(db.todos).get(), isEmpty);
      expect(await db.select(db.todoTags).get(), isEmpty);
      expect((await db.captureDao.getCapture('wfc3'))!.clarifiedAt, isNull);
      expect(afterCount, 0);
    });

    testWidgets('cancelling on a Capture writes nothing and does not fire',
        (tester) async {
      final capture = await _insertCapture(db, id: 'wfc1');
      await _insertPersonTag(db, id: 'alice', name: 'Alice');
      var afterCount = 0;
      await tester.pumpWidget(_captureHarness(
        db,
        capture: capture,
        personTags: [_personTag('alice', 'Alice')],
        onAfterRoute: (_) async => afterCount++,
      ));

      await tester.tap(find.text('Waiting For'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(await db.select(db.todos).get(), isEmpty,
          reason: 'no Outcome may be carved for a cancelled pick');
      expect((await db.captureDao.getCapture('wfc1'))!.clarifiedAt, isNull);
      expect(afterCount, 0);
    });

    testWidgets('confirming on a Capture carves an Outcome with the delegate',
        (tester) async {
      final capture = await _insertCapture(db, id: 'wfc2', title: 'Ask Bob');
      await _insertPersonTag(db, id: 'alice', name: 'Alice');
      ProcessAction? afterArg;
      await tester.pumpWidget(_captureHarness(
        db,
        capture: capture,
        personTags: [_personTag('alice', 'Alice')],
        onAfterRoute: (action) async => afterArg = action,
      ));

      await tester.tap(find.text('Waiting For'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pumpAndSettle();

      // The Outcome does not exist until this commit, so the delegate can only
      // have arrived via clarifyCaptureToOutcome's personTagIds.
      final outcomes = await db.select(db.todos).get();
      expect(outcomes, hasLength(1));
      expect(outcomes.single.title, 'Ask Bob');
      // Delegation is carried by the person tag; `waitingFor` routes intent to
      // `next` like any other actionable Outcome.
      expect(outcomes.single.intent, 'next');
      expect(
        await db.todoDao.getPersonTagIdsForTodo(outcomes.single.id),
        contains('alice'),
      );
      expect((await db.captureDao.getCapture('wfc2'))!.clarifiedAt, isNotNull);
      expect(afterArg, ProcessAction.waitingFor);
    });
  });

  group('ProcessToHandlers — nextActionDialog modifier', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets(
        'Next with the modifier excepted writes immediately; dialog never '
        'opens', (tester) async {
      final todo = await _insertTodo(db, id: 'nd1');
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        except: const {ProcessAction.nextActionDialog},
      ));

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      // Dialog absent — except reverts Next to a plain one-tap route.
      expect(find.byType(NextActionDialog), findsNothing);
      final row = await db.todoDao.getTodo('nd1');
      expect(row?.intent, 'next');
    });

    testWidgets(
        'Next opens the prefilled dialog by default; cancel = no write',
        (tester) async {
      // The prefill comes from the caller-supplied `currentActionText`, which
      // is the caller's projection of the Action grain (ADR-0001 story 3 —
      // `getCurrentActionTexts`, plumbed through `OutcomeSubject`). The widget
      // itself does no DB read, so the seeded Action row and the argument are
      // deliberately given *different* text: that is what discriminates the
      // three candidate sources apart. With every value set to the same string
      // the assertion could not tell the argument from the store, the title, or
      // the retired cursor.
      final todo = await _insertTodo(db, id: 'nd2');
      await seedCurrentAction(
        db,
        outcomeId: 'nd2',
        text: 'a row the widget never reads',
        userId: _userId,
      );
      // No include needed — the dialog modifier is on by default.
      await tester
          .pumpWidget(_harness(db, todo: todo, currentActionText: 'old'));

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      // Dialog open with prefilled text.
      expect(find.byType(NextActionDialog), findsOneWidget);
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byType(NextActionDialog),
          matching: find.byType(TextField),
        ),
      );
      expect(field.controller?.text, 'old',
          reason: 'the prefill is the caller-supplied Action-grain projection — '
              'not the Outcome title, not the retired cursor, and not a direct '
              'read of the seeded `actions` row');

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // No DAO write happened — lastClarifiedAt remains null.
      final row = await db.todoDao.getTodo('nd2');
      expect(row?.lastClarifiedAt, isNull);
    });

    testWidgets(
        'Next (dialog default-on) — Save writes the new Action and routes',
        (tester) async {
      final todo = await _insertTodo(db, id: 'nd3');
      await tester.pumpWidget(_harness(db, todo: todo));

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.descendant(
          of: find.byType(NextActionDialog),
          matching: find.byType(TextField),
        ),
        'Draft proposal',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('nd3');
      expect(row?.intent, 'next');
      expect((await db.actionDao.getCurrentAction('nd3'))?.actionText,
          'Draft proposal');
    });

    testWidgets(
        "the dialog's phrase wins over the card's, but the card's effort "
        'values survive', (tester) async {
      // The merge of dialog phrase and card draft. A bare
      // `dialogPhrase ?? draft.action?.text` would take the phrase and drop
      // the energy and estimate the user had already set on the card.
      final capture = await _insertCapture(db, id: 'md1', title: 'Fragment');
      await tester.pumpWidget(ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                ProcessToHandlers(
                  subject: CaptureSubject(
                    capture: capture,
                    draft: () => const ClarifyDraft(
                      title: 'Fragment',
                      action: ActionDraft(
                        text: 'Fragment',
                        energyLevel: 'high',
                        timeEstimateMinutes: 45,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ));

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(NextActionDialog),
          matching: find.byType(TextField),
        ),
        'Draft the proposal',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final outcomeIds = await db.captureDao.outcomeIdsForCapture('md1');
      final outcomeId = outcomeIds.single;
      final action = await db.actionDao.getCurrentAction(outcomeId);
      expect(action?.actionText, 'Draft the proposal',
          reason: "the dialog's phrase wins");
      expect(action?.energyLevel, 'high',
          reason: "the card's effort is not dropped by the override");
      expect(action?.timeEstimate, 45);
    });

    testWidgets('on a Capture the dialog is seeded from the draft (#689)',
        (tester) async {
      // `CaptureSubject.currentActionText` is null by contract — no Outcome
      // exists yet to carry an Action — so seeding from it would open the
      // dialog empty and make the user retype what the card already says.
      // The seed comes from the draft instead, which carries
      // `ClarifyDraft.assemble`'s title mirror. Draft title and Capture title
      // are deliberately *different* strings here: with both the same the
      // assertion could not tell the draft from the subject.
      final capture = await _insertCapture(db, id: 'sd1', title: 'stale row');
      await tester.pumpWidget(ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                ProcessToHandlers(
                  subject: CaptureSubject(
                    capture: capture,
                    draft: () => const ClarifyDraft(
                      title: 'Renew car insurance',
                      action: ActionDraft(text: 'Renew car insurance'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ));

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      expect(find.byType(NextActionDialog), findsOneWidget);
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byType(NextActionDialog),
          matching: find.byType(TextField),
        ),
      );
      expect(field.controller?.text, 'Renew car insurance',
          reason: 'the seed is the live draft, read at dialog-open time — not '
              'the Capture row the card was built from');
    });

    testWidgets('the seed is read when the dialog opens, not at build time',
        (tester) async {
      // [CaptureSubject.draft] is a callback precisely because the clarify
      // card's title lives in a TextEditingController that does not rebuild
      // the bar on every keystroke. A seed snapshotted at build time would be
      // whatever the field held when the card first rendered.
      final capture = await _insertCapture(db, id: 'sd2', title: 'Fragment');
      var draftText = 'before typing';
      await tester.pumpWidget(ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                ProcessToHandlers(
                  subject: CaptureSubject(
                    capture: capture,
                    draft: () => ClarifyDraft(
                      title: draftText,
                      action: ActionDraft(text: draftText),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ));
      await tester.pump();

      draftText = 'after typing';
      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byType(NextActionDialog),
          matching: find.byType(TextField),
        ),
      );
      expect(field.controller?.text, 'after typing');
    });

    testWidgets('a Capture with no draft Action opens the dialog empty',
        (tester) async {
      // A blank title nulls the whole draft Action (ClarifyDraft.assemble), so
      // there is no proposal to seed. Reachable only past the surfaces' own
      // blank-title gate, but the seed must not throw on it.
      final capture = await _insertCapture(db, id: 'sd3', title: 'Fragment');
      await tester.pumpWidget(ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                ProcessToHandlers(
                  subject: CaptureSubject(
                    capture: capture,
                    draft: () => const ClarifyDraft(title: ''),
                  ),
                ),
              ],
            ),
          ),
        ),
      ));

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byType(NextActionDialog),
          matching: find.byType(TextField),
        ),
      );
      expect(field.controller?.text, isEmpty);
    });

    testWidgets('a Capture reads "Set next action", never "Update" (#689)',
        (tester) async {
      // The heading turns on whether an Action already exists, not on whether
      // the field happens to be full. A Capture's seed is a *proposal*
      // mirrored from the title for an Action that does not exist yet, so
      // inferring "Update" from the prefilled field would offer to update
      // something the user has never written.
      final capture = await _insertCapture(db, id: 'hd1', title: 'Fragment');
      await tester.pumpWidget(ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                ProcessToHandlers(
                  subject: CaptureSubject(
                    capture: capture,
                    draft: () => const ClarifyDraft(
                      title: 'Fragment',
                      action: ActionDraft(text: 'Fragment'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ));

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      expect(find.text('Set next action'), findsOneWidget);
      expect(find.text('Update next action'), findsNothing);
    });

    testWidgets('an Outcome with a current Action still reads "Update"',
        (tester) async {
      final todo = await _insertTodo(db, id: 'hd2');
      await tester
          .pumpWidget(_harness(db, todo: todo, currentActionText: 'old'));

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      expect(find.text('Update next action'), findsOneWidget);
    });

    testWidgets('an Actionless Outcome reads "Set"', (tester) async {
      final todo = await _insertTodo(db, id: 'hd3');
      await tester.pumpWidget(_harness(db, todo: todo));

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      expect(find.text('Set next action'), findsOneWidget);
    });
  });

  group('ProcessToHandlers — blank save means the title (#691)', () {
    // The title-as-action fallback. A blank Save resolves and advances; only
    // Cancel leaves the item unresolved. The two are distinguished by the
    // dialog's *type*: Cancel resolves to null, a blank Save to ''. Any
    // refactor that collapses them (`result?.isEmpty ?? true`) breaks the
    // cancel contract while leaving every other assertion green, which is why
    // both are pinned here separately.
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets(
        'blank Save on an Actionless Outcome routes to Next and mirrors the '
        'title into the current Action', (tester) async {
      final todo = await _insertTodo(db, id: 'bs1', title: 'Call the dentist');
      final fired = <ProcessAction>[];
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        onAfterRoute: (a) async => fired.add(a),
      ));

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('bs1');
      expect(row?.intent, 'next');
      expect(row?.clarified, isTrue);
      expect(row?.lastClarifiedAt, isNotNull);
      expect((await db.actionDao.getCurrentAction('bs1'))?.actionText,
          'Call the dentist',
          reason: 'for a simple Outcome the title *is* the physical action');
      expect(fired, [ProcessAction.nextActionDialog],
          reason: 'the hook fires exactly once, and a landed route backs it');
    });

    testWidgets(
        'blank Save on an Outcome that already has an Action routes without '
        'clobbering the phrase', (tester) async {
      // The fallback is Actionless-only. Clearing the field is not the
      // affordance for retiring an Action (Abandon is), and the codebase's
      // standing bias is never to destroy typed text.
      final todo = await _insertTodo(db, id: 'bs2', title: 'Run the retro');
      await seedCurrentAction(
        db,
        outcomeId: 'bs2',
        text: 'Book the room',
        userId: _userId,
      );
      final fired = <ProcessAction>[];
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        currentActionText: 'Book the room',
        onAfterRoute: (a) async => fired.add(a),
      ));

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();
      // Clear the prefill, then save.
      await tester.enterText(
        find.descendant(
          of: find.byType(NextActionDialog),
          matching: find.byType(TextField),
        ),
        '',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('bs2');
      expect(row?.intent, 'next');
      expect(row?.lastClarifiedAt, isNotNull,
          reason: 'the route still lands — only the Action is left alone');
      expect((await db.actionDao.getCurrentAction('bs2'))?.actionText,
          'Book the room',
          reason: 'a deliberate phrase survives a blank save');
      expect(fired, [ProcessAction.nextActionDialog]);
    });

    testWidgets(
        'blank Save on a blank-titled Outcome stalls: no route, no Action, '
        'no hook', (tester) async {
      // With neither a typed phrase nor a title there is nothing to stand in
      // as the Action, so routing would manufacture a permanently re-armed
      // row (the Actionless branch of _needsReviewWhere has no freshness
      // gate). Stalling is the honest outcome. Near-unreachable through the
      // UI — the clarify card refuses a blank title and the routing buttons
      // are disabled — but reachable via a synced-in row.
      final todo = await _insertTodo(db, id: 'bs3', title: '');
      final fired = <ProcessAction>[];
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        onAfterRoute: (a) async => fired.add(a),
      ));

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull,
          reason: 'setCurrentActionTextIfActionless throws on blank text — the '
              'caller must guard rather than let an ArgumentError escape');
      final row = await db.todoDao.getTodo('bs3');
      expect(row?.lastClarifiedAt, isNull, reason: 'no route landed');
      expect(await db.actionDao.getCurrentAction('bs3'), isNull);
      expect(fired, isEmpty);
    });

    testWidgets('Cancel routes nothing and does not fire the hook',
        (tester) async {
      final todo = await _insertTodo(db, id: 'bs4', title: 'Call the dentist');
      final fired = <ProcessAction>[];
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        onAfterRoute: (a) async => fired.add(a),
      ));

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('bs4');
      expect(row?.lastClarifiedAt, isNull);
      expect(await db.actionDao.getCurrentAction('bs4'), isNull);
      expect(fired, isEmpty,
          reason: 'cancel is not a blank save — it must leave the item '
              'unresolved so the callsite does not advance');
    });

    testWidgets('barrier dismiss behaves as Cancel, not as a blank save',
        (tester) async {
      final todo = await _insertTodo(db, id: 'bs5', title: 'Call the dentist');
      final fired = <ProcessAction>[];
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        onAfterRoute: (a) async => fired.add(a),
      ));

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.byType(NextActionDialog), findsNothing);
      expect((await db.todoDao.getTodo('bs5'))?.lastClarifiedAt, isNull);
      expect(await db.actionDao.getCurrentAction('bs5'), isNull);
      expect(fired, isEmpty);
    });

    testWidgets('system back behaves as Cancel, not as a blank save',
        (tester) async {
      final todo = await _insertTodo(db, id: 'bs6', title: 'Call the dentist');
      final fired = <ProcessAction>[];
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        onAfterRoute: (a) async => fired.add(a),
      ));

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(NextActionDialog), findsNothing);
      expect((await db.todoDao.getTodo('bs6'))?.lastClarifiedAt, isNull);
      expect(await db.actionDao.getCurrentAction('bs6'), isNull);
      expect(fired, isEmpty);
    });

    testWidgets(
        'blank Save on a Capture mints the Outcome carrying the draft mirror',
        (tester) async {
      // No Capture surface enables the modifier today, but #689 may. The
      // Capture arm needs no fallback of its own: ClarifyDraft.assemble
      // already mirrors the title into the draft's Action, and _mergedAction
      // keeps it when the dialog returns blank.
      final capture = await _insertCapture(db, id: 'bs7', title: 'Fragment');
      final fired = <ProcessAction>[];
      await tester.pumpWidget(ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                ProcessToHandlers(
                  subject: CaptureSubject(
                    capture: capture,
                    draft: () => const ClarifyDraft(
                      title: 'Fragment',
                      action: ActionDraft(text: 'Fragment'),
                    ),
                  ),
                  onAfterRoute: (a) async => fired.add(a),
                ),
              ],
            ),
          ),
        ),
      ));

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final outcomeId =
          (await db.captureDao.outcomeIdsForCapture('bs7')).single;
      expect((await db.actionDao.getCurrentAction(outcomeId))?.actionText,
          'Fragment');
      expect((await db.todoDao.getTodo(outcomeId))?.intent, 'next');
      expect(fired, [ProcessAction.nextActionDialog]);
    });
  });

  group('ProcessToHandlers — person tags survive intent transitions', () {
    // Orthogonality model: the action-axis (intent) and the delegate-axis
    // (person tags) are independent. A delegated task can have any intent
    // applied to it; person tags are mutated only via the picker.
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets(
        'Trash on a delegated todo preserves person tags (orthogonality)',
        (tester) async {
      await _insertTodo(db, id: 'wt1');
      await _insertPersonTag(db, id: 'alice', name: 'Alice');
      await db.tagDao.assignTag('wt1', 'alice', _userId);
      final todo = (await db.todoDao.getTodo('wt1'))!;

      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        personTags: [_personTag('alice', 'Alice')],
      ));

      await tester.tap(find.text('Trash'));
      await tester.pumpAndSettle();

      final tagIds = await db.todoDao.getPersonTagIdsForTodo('wt1');
      expect(tagIds, contains('alice'),
          reason: 'intent change must not silently drop the delegate');
      final row = await db.todoDao.getTodo('wt1');
      expect(row?.intent, 'trash');
    });

    testWidgets(
        'Next on a delegated todo preserves person tags (orthogonality)',
        (tester) async {
      // The example from #276: "task is waiting for trixy, but
      // 'call trixy for update' could be next action." Promoting to Next
      // (through the default-on dialog) must not strip Trixy.
      await _insertTodo(db, id: 'wt2');
      await _insertPersonTag(db, id: 'trixy', name: 'Trixy');
      await db.tagDao.assignTag('wt2', 'trixy', _userId);
      final todo = (await db.todoDao.getTodo('wt2'))!;

      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        personTags: [_personTag('trixy', 'Trixy')],
      ));

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(NextActionDialog),
          matching: find.byType(TextField),
        ),
        'Call Trixy for update',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final tagIds = await db.todoDao.getPersonTagIdsForTodo('wt2');
      expect(tagIds, contains('trixy'),
          reason: 'next-action route preserves delegate-axis state');
      final row = await db.todoDao.getTodo('wt2');
      expect(row?.intent, 'next');
    });

    testWidgets(
        'Trash on a non-delegated todo routes without touching tag set',
        (tester) async {
      final todo = await _insertTodo(db, id: 'wt3');

      await tester.pumpWidget(_harness(db, todo: todo));

      await tester.tap(find.text('Trash'));
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('wt3');
      expect(row?.intent, 'trash');
    });
  });

  group('ProcessToHandlers — the current Action is on the user-action axis',
      () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets(
        'Waiting For (picker confirm) does NOT mint a current Action',
        (tester) async {
      // Orthogonality: routing to waitingFor sets intent + delegate, not
      // the user-action phrase. The dialog modifier (or a callsite-owned
      // setter) is the only path that writes the Action.
      final todo = await _insertTodo(db, id: 'na1');
      await _insertPersonTag(db, id: 'alice', name: 'Alice');
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        personTags: [_personTag('alice', 'Alice')],
      ));

      await tester.tap(find.text('Waiting For'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pumpAndSettle();

      expect(await db.actionDao.getCurrentAction('na1'), isNull,
          reason: 'waitingFor route must not synthesise a phrase');
    });

    testWidgets(
        'Next with the dialog excepted does NOT overwrite an existing '
        'current Action', (tester) async {
      final todo = await _insertTodo(db, id: 'na2');
      // Seed the phrase at the Action grain — the only grain there is. Seeding
      // the retired cursor instead would leave a genuinely Actionless Outcome
      // and the assertion below would pass without protecting anything.
      await seedCurrentAction(
        db,
        outcomeId: 'na2',
        text: 'pre-existing phrase',
        userId: _userId,
      );
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        except: const {ProcessAction.nextActionDialog},
      ));

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      expect((await db.actionDao.getCurrentAction('na2'))?.actionText,
          'pre-existing phrase',
          reason: 'plain next-action route is intent-only');
    });
  });

  group('ProcessToHandlers — onAfterRoute', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets('fires once with the matching action on success',
        (tester) async {
      final todo = await _insertTodo(db, id: 'a1');
      final fired = <ProcessAction>[];
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        onAfterRoute: (action) async => fired.add(action),
      ));

      await tester.tap(find.text('Trash'));
      await tester.pumpAndSettle();

      expect(fired, [ProcessAction.trash]);
    });

    testWidgets(
        'does NOT fire when the row was deleted between render and tap',
        (tester) async {
      // Snapshot-based callsites can lose a row between render and tap
      // (sync/another device hard-deletes it). The widget pre-checks existence
      // rather than reading the write's affected-row count — the routing write
      // is a multi-statement transaction whose count says nothing about the
      // subject in particular — and bails before firing onAfterRoute (which
      // would advance the cursor + record a phantom routing record).
      final todo = await _insertTodo(db, id: 'gone1');
      final fired = <ProcessAction>[];
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        onAfterRoute: (action) async => fired.add(action),
      ));

      // Hard-delete the row out from under the widget — simulates a race
      // between snapshot load and the user's tap.
      await (db.delete(db.todos)..where((t) => t.id.equals('gone1'))).go();

      await tester.tap(find.text('Trash'));
      await tester.pumpAndSettle();

      expect(fired, isEmpty,
          reason: 'must not advance the cursor on a deleted snapshot row');
    });

    testWidgets('a failed write reports the error and does NOT fire',
        (tester) async {
      final todo = await _insertTodo(db, id: 'boom1');
      final fired = <ProcessAction>[];
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        clarificationService: _FailingClarificationService(db),
        onAfterRoute: (action) async => fired.add(action),
      ));

      await tester.tap(find.text('Trash'));
      await tester.pumpAndSettle();

      // This widget owns the tap handler, so no callsite can catch the
      // failure — without this the write escapes as an unhandled async error
      // and every clarify surface silently does nothing.
      expect(find.text('Operation failed. Please try again.'), findsOneWidget);
      expect(fired, isEmpty,
          reason: 'the write did not land, so nothing may be recorded');
    });

    testWidgets('a failed Discard reports the error and leaves the Capture',
        (tester) async {
      final capture = await _insertCapture(db, id: 'boom3');
      final fired = <ProcessAction>[];
      await tester.pumpWidget(_captureHarness(
        db,
        capture: capture,
        clarificationService: _FailingClarificationService(db),
        onAfterRoute: (action) async => fired.add(action),
      ));

      await tester.tap(find.text('Discard Capture'));
      await tester.pumpAndSettle();

      // Discard runs through `discardCapture`, not `clarifyToOutcome` — a
      // separate write path, so it needs its own failure coverage.
      expect(find.text('Operation failed. Please try again.'), findsOneWidget);
      expect(fired, isEmpty,
          reason: 'the write did not land, so nothing may be recorded');
      // The verdict never committed, so the Capture is still in the Inbox for
      // the user to retry rather than silently gone.
      expect((await db.captureDao.getCapture('boom3'))!.clarifiedAt, isNull);
    });

    testWidgets('a failing onAfterRoute does not report the write as failed',
        (tester) async {
      final todo = await _insertTodo(db, id: 'boom2');
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        onAfterRoute: (_) async => throw StateError('bookkeeping failed'),
      ));

      await tester.tap(find.text('Trash'));
      await tester.pumpAndSettle();

      // The write landed — only the callsite's post-route bookkeeping blew up.
      expect((await db.todoDao.getTodo('boom2'))!.intent, 'trash');
      // So "please try again" would be wrong advice: it invites the user to
      // redo a route that already succeeded.
      expect(find.text('Operation failed. Please try again.'), findsNothing);
      expect(
        find.textContaining('Saved, but finishing up failed'),
        findsOneWidget,
      );
    });

    testWidgets(
        'nextActionDialog modifier reports nextActionDialog (not next)',
        (tester) async {
      final todo = await _insertTodo(db, id: 'a2');
      final fired = <ProcessAction>[];
      // Dialog modifier is default-on — no include needed.
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        onAfterRoute: (action) async => fired.add(action),
      ));

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(NextActionDialog),
          matching: find.byType(TextField),
        ),
        'Do thing',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(fired, [ProcessAction.nextActionDialog]);
    });
  });

  group('ProcessToHandlers — reclarify sub-flow', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    /// The full ClarifyCard + Scaffold AppBar exceeds the default 600px test
    /// viewport, pushing the bottom action buttons off-screen and making
    /// `tester.tap` miss. Enlarge the viewport so every sub-flow button is
    /// visible without per-test scrolling.
    Future<void> useTallViewport(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() async => tester.binding.setSurfaceSize(null));
    }

    testWidgets(
        'tapping Re-clarify… opens the ClarifyCard sub-flow on this item, '
        'scaffolded with the shared AppTitleBar and pinned capture (#519)',
        (tester) async {
      await useTallViewport(tester);
      final todo = await _insertTodo(db, id: 'rc1', title: 'Pick a topic');
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        include: const {ProcessAction.reclarify},
      ));

      await tester.tap(find.text('Re-clarify…'));
      await tester.pumpAndSettle();

      // Sub-flow card is on screen, scaffolded with the shared AppTitleBar —
      // no bespoke AppBar remains in this pushed route (#519).
      expect(find.byType(ClarifyCard), findsOneWidget);
      expect(find.widgetWithText(AppTitleBar, 'Re-clarify'), findsOneWidget);
      expect(find.byType(AppBar), findsNothing);
      // Capture stays available on this surface like every other adopter —
      // never a raw find.byKey (docs/TESTING.md), since the budgeted
      // overflow can move the action into the ⋮ menu.
      expect(await findBarAction(tester, const Key('capture_action')),
          findsOneWidget);
    });

    testWidgets(
        'routing inside the sub-flow closes it and bubbles the action via '
        'onAfterRoute', (tester) async {
      await useTallViewport(tester);
      final todo = await _insertTodo(db, id: 'rc2');
      final fired = <ProcessAction>[];
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        include: const {ProcessAction.reclarify},
        onAfterRoute: (action) async => fired.add(action),
      ));

      await tester.tap(find.text('Re-clarify…'));
      await tester.pumpAndSettle();

      // Route inside the sub-flow via Trash (no sub-dialog to dismiss).
      await tester.tap(find.text('Trash'));
      await tester.pumpAndSettle();

      // Sub-flow is gone, outer received the routed action.
      expect(find.byType(ClarifyCard), findsNothing);
      expect(fired, [ProcessAction.trash]);
      final row = await db.todoDao.getTodo('rc2');
      expect(row?.intent, 'trash',
          reason: 'inner ProcessToHandlers owns the routing write');
    });

    testWidgets(
        'backing out of the sub-flow without routing bubbles as keep',
        (tester) async {
      await useTallViewport(tester);
      final todo = await _insertTodo(db, id: 'rc3');
      final fired = <ProcessAction>[];
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        include: const {ProcessAction.reclarify},
        onAfterRoute: (action) async => fired.add(action),
      ));

      await tester.tap(find.text('Re-clarify…'));
      await tester.pumpAndSettle();

      // Pop the route (back arrow) without routing.
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(ClarifyCard), findsNothing);
      expect(fired, [ProcessAction.keep],
          reason: 'back-out of the sub-flow maps to keep');
      final row = await db.todoDao.getTodo('rc3');
      // No routing happened: intent unchanged from the seed.
      expect(row?.intent, 'next');
      // Back-out invokes the real _keep(): the todo must be stamped so the
      // review step advances past it on the next pass instead of resurfacing.
      expect(row?.lastClarifiedAt, isNotNull,
          reason: 'back-out must stamp lastClarifiedAt like a Keep tap');
    });
  });

  group('ProcessToHandlers — the dialog offers the planned queue (#723)', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    Future<void> seedQueue(String outcomeId) async {
      await seedPlannedAction(db,
          outcomeId: outcomeId,
          text: 'Step one',
          userId: _userId,
          id: 'p1',
          position: 0);
      await seedPlannedAction(db,
          outcomeId: outcomeId,
          text: 'Step two',
          userId: _userId,
          id: 'p2',
          position: 1);
    }

    Future<void> openDialog(WidgetTester tester) async {
      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();
      expect(find.byType(NextActionDialog), findsOneWidget);
    }

    testWidgets('an empty queue renders no promote rows (byte-identical dialog)',
        (tester) async {
      final todo = await _insertTodo(db, id: 'q0');
      await tester.pumpWidget(_harness(db, todo: todo));

      await openDialog(tester);
      expect(find.byKey(const Key('next_action_promote_p1')), findsNothing);
      expect(find.text('Step one'), findsNothing);
    });

    testWidgets(
        'promoting a planned Action on an Actionless Outcome makes it current '
        'and routes to Next', (tester) async {
      final todo = await _insertTodo(db, id: 'q1');
      await seedQueue('q1');
      final fired = <ProcessAction>[];
      await tester.pumpWidget(
          _harness(db, todo: todo, onAfterRoute: (a) async => fired.add(a)));

      await openDialog(tester);
      expect(find.text('Step one'), findsOneWidget);
      expect(find.text('Step two'), findsOneWidget);

      await tester.tap(find.text('Step one'));
      await tester.pumpAndSettle();

      expect((await db.actionDao.getCurrentAction('q1'))?.actionText,
          'Step one');
      expect((await db.actionDao.getPlannedActions('q1')).map((a) => a.actionText),
          ['Step two'], reason: 'the un-chosen planned row stays planned');
      expect((await db.todoDao.getTodo('q1'))?.intent, 'next');
      expect((await db.todoDao.getTodo('q1'))?.lastClarifiedAt, isNotNull);
      expect(fired, [ProcessAction.nextActionDialog]);
    });

    testWidgets(
        'a promote whose planned row vanished writes no route and leaves the '
        'Outcome Actionless (no-op guard)', (tester) async {
      // Seeded on Someday so a committed route (→ Next) would be detectable —
      // proving the guard suppressed `_commit`, not merely that no Action landed.
      final todo = await _insertTodo(db, id: 'q2', intent: 'maybe');
      await seedQueue('q2');
      final fired = <ProcessAction>[];
      await tester.pumpWidget(
          _harness(db, todo: todo, onAfterRoute: (a) async => fired.add(a)));

      await openDialog(tester);
      // The chosen planned row vanishes (synced away) between the dialog's
      // snapshot and the tap: a raw row delete, as the sync bridge lands one —
      // so the real `promotePlannedAction` no-ops against a missing row rather
      // than a stubbed service standing in for it.
      await (db.delete(db.actions)..where((a) => a.id.equals('p1'))).go();
      await tester.tap(find.text('Step one'));
      await tester.pumpAndSettle();

      // The promote no-oped, so no current Action exists — the guard must stop
      // `_commit` from stranding a still-Actionless Outcome on Next.
      expect(await db.actionDao.getCurrentAction('q2'), isNull);
      expect((await db.todoDao.getTodo('q2'))?.intent, 'maybe',
          reason: 'no route committed, so the Outcome stays on Someday');
      expect((await db.todoDao.getTodo('q2'))?.lastClarifiedAt, isNull,
          reason: 'no route landed, so nothing stamped');
      expect(fired, isEmpty);
    });

    testWidgets(
        'promoting over a current Action opens the Replace confirm; confirming '
        'supersedes and promotes', (tester) async {
      final todo = await _insertTodo(db, id: 'q3');
      await seedCurrentAction(
          db, outcomeId: 'q3', text: 'do it', userId: _userId);
      await seedQueue('q3');
      final fired = <ProcessAction>[];
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        currentActionText: 'do it',
        onAfterRoute: (a) async => fired.add(a),
      ));

      await openDialog(tester);
      await tester.tap(find.text('Step one'));
      await tester.pumpAndSettle();

      // The shared "Replace current action" confirm — not a silent supersede.
      expect(find.byKey(const Key('plan_replace_confirm')), findsOneWidget);
      await tester.tap(find.byKey(const Key('plan_replace_confirm')));
      await tester.pumpAndSettle();

      expect((await db.actionDao.getCurrentAction('q3'))?.actionText,
          'Step one');
      expect((await db.actionDao.getPlannedActions('q3')).map((a) => a.actionText),
          ['Step two'], reason: 'only the chosen row is promoted');
      // The incumbent Action is retired, not deleted (supersede, not remove).
      expect((await db.actionDao.getTerminatedActions('q3')).map((t) => t.action.actionText),
          contains('do it'));
      expect((await db.todoDao.getTodo('q3'))?.intent, 'next');
      expect(fired, [ProcessAction.nextActionDialog]);
    });

    testWidgets('declining the Replace confirm writes nothing and does not '
        'notify', (tester) async {
      // On Someday, with a current Action and a queue — so a committed route
      // would be visible as `intent='next'`.
      final todo = await _insertTodo(db, id: 'q4', intent: 'maybe');
      await seedCurrentAction(
          db, outcomeId: 'q4', text: 'do it', userId: _userId);
      await seedQueue('q4');
      final fired = <ProcessAction>[];
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        currentActionText: 'do it',
        onAfterRoute: (a) async => fired.add(a),
      ));

      await openDialog(tester);
      await tester.tap(find.text('Step one'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('plan_replace_confirm')), findsOneWidget);

      // System back dismisses the confirm sheet — a declined replace.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect((await db.actionDao.getCurrentAction('q4'))?.actionText, 'do it',
          reason: 'the incumbent Action survives a declined replace');
      expect((await db.actionDao.getPlannedActions('q4')).map((a) => a.actionText),
          ['Step one', 'Step two']);
      expect((await db.todoDao.getTodo('q4'))?.intent, 'maybe',
          reason: 'a declined replace commits no route');
      expect((await db.todoDao.getTodo('q4'))?.lastClarifiedAt, isNull,
          reason: 'a declined replace stamps nothing');
      expect(fired, isEmpty,
          reason: 'a declined confirm leaves the item unresolved');
    });

    testWidgets(
        'a current Action swapped under the open confirm is NOT superseded '
        '(expectedCurrentActionId guard)', (tester) async {
      final todo = await _insertTodo(db, id: 'q6');
      await seedCurrentAction(
          db, outcomeId: 'q6', text: 'do it', userId: _userId, id: 'cur-old');
      await seedQueue('q6');
      final fired = <ProcessAction>[];
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        currentActionText: 'do it',
        onAfterRoute: (a) async => fired.add(a),
      ));

      await openDialog(tester);
      await tester.tap(find.text('Step one'));
      await tester.pumpAndSettle();
      // The confirm read 'do it' (cur-old) as the current Action to replace.
      expect(find.byKey(const Key('plan_replace_confirm')), findsOneWidget);

      // Sync lands a *different* current Action while the confirm is open: the
      // old current is gone and a new one is installed. Raw writes, as the sync
      // bridge would.
      await (db.delete(db.actions)..where((a) => a.id.equals('cur-old'))).go();
      await db.into(db.actions).insert(ActionsCompanion(
            id: const Value('cur-new'),
            outcomeId: const Value('q6'),
            userId: const Value(_userId),
            actionText: const Value('do it differently'),
            role: const Value('current'),
            createdAt: Value(DateTime.now()),
          ));

      await tester.tap(find.byKey(const Key('plan_replace_confirm')));
      await tester.pumpAndSettle();

      // The guard aborts: the synced-in current survives un-retired and the
      // chosen planned row is NOT promoted. Without expectedCurrentActionId,
      // 'do it differently' — an Action the user never saw — would be silently
      // superseded.
      final current = await db.actionDao.getCurrentAction('q6');
      expect(current?.id, 'cur-new');
      expect(current?.actionText, 'do it differently');
      expect((await db.actionDao.getPlannedActions('q6')).map((a) => a.actionText),
          ['Step one', 'Step two']);
      expect(await db.actionDao.getTerminatedActions('q6'), isEmpty,
          reason: 'the aborted replace retires nothing');
      expect(fired, isEmpty, reason: 'the aborted replace commits no route');
    });

    testWidgets('a blank Save with a queue mirrors the title and leaves the '
        'planned rows untouched', (tester) async {
      final todo = await _insertTodo(db, id: 'q5', title: 'Ship it');
      await seedQueue('q5');
      final fired = <ProcessAction>[];
      await tester.pumpWidget(
          _harness(db, todo: todo, onAfterRoute: (a) async => fired.add(a)));

      await openDialog(tester);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // The fallback still fires — the user saw the queue and declined it — but
      // it is no longer the *only* thing standing between them: the queue is
      // intact (#723 keeps the fallback rather than auto-promoting the head).
      expect((await db.actionDao.getCurrentAction('q5'))?.actionText, 'Ship it');
      expect((await db.actionDao.getPlannedActions('q5')).map((a) => a.actionText),
          ['Step one', 'Step two']);
      expect(fired, [ProcessAction.nextActionDialog]);
    });

    testWidgets('a Capture never loads or offers a queue', (tester) async {
      final capture = await _insertCapture(db, id: 'qc', title: 'Fragment');
      await tester.pumpWidget(ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                ProcessToHandlers(
                  subject: CaptureSubject(
                    capture: capture,
                    draft: () => const ClarifyDraft(title: 'Fragment'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ));

      await openDialog(tester);
      expect(find.byKey(const Key('next_action_promote_p1')), findsNothing);
    });
  });
}

