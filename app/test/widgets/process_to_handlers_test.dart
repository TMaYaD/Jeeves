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
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/tags_provider.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/services/clarification_service.dart';
import 'package:jeeves/widgets/clarify_card.dart';
import 'package:jeeves/widgets/next_action_dialog.dart';
import 'package:jeeves/widgets/process_to_handlers.dart';

import '../test_helpers.dart';

const _userId = 'local';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

Future<Todo> _insertTodo(
  GtdDatabase db, {
  required String id,
  String title = 'Task',
  String? nextActionText,
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
        nextActionText:
            nextActionText != null ? Value(nextActionText) : const Value.absent(),
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
    String? nextActionText,
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
              subject: OutcomeSubject(todo),
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
      expect(find.text('Discard'), findsNothing);
    });

    testWidgets('trash is labelled "Discard" on a Capture', (tester) async {
      final capture = await _insertCapture(db, id: 'c7');
      await tester.pumpWidget(_captureHarness(db, capture: capture));

      // A discarded Capture creates no Outcome, so it never reaches that List.
      // Naming it "Trash" would promise a destination it never arrives at.
      expect(find.text('Discard'), findsOneWidget);
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

    testWidgets('Someday clears doneAt on a previously-done todo',
        (tester) async {
      await _insertTodo(db, id: 'd2');
      await db.todoDao.applyRouting('d2', to: RoutingKind.done);
      final todo = (await db.todoDao.getTodo('d2'))!;

      await tester.pumpWidget(_harness(db, todo: todo));
      await tester.tap(find.text('Someday'));
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('d2');
      expect(row?.doneAt, isNull);
      expect(row?.intent, 'maybe');
    });

    testWidgets('Waiting For clears doneAt on a previously-done todo',
        (tester) async {
      await _insertTodo(db, id: 'd3');
      await db.todoDao.applyRouting('d3', to: RoutingKind.done);
      final todo = (await db.todoDao.getTodo('d3'))!;
      await _insertPersonTag(db, id: 'alice', name: 'Alice');

      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        personTags: [_personTag('alice', 'Alice')],
      ));
      await tester.tap(find.text('Waiting For'));
      await tester.pumpAndSettle();

      // Confirm picker (select Alice). The picker confirm is a FilledButton
      // labelled "Done"; the route bar also has a "Done" OutlinedButton, so
      // disambiguate by widget type.
      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('d3');
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
      final todo =
          await _insertTodo(db, id: 'nd1', nextActionText: 'pre-existing');
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
      final todo = await _insertTodo(db, id: 'nd2', nextActionText: 'old');
      // No include needed — the dialog modifier is on by default.
      await tester.pumpWidget(_harness(db, todo: todo));

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
      expect(field.controller?.text, 'old');

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // No DAO write happened — lastClarifiedAt remains null.
      final row = await db.todoDao.getTodo('nd2');
      expect(row?.lastClarifiedAt, isNull);
    });

    testWidgets(
        'Next (dialog default-on) — Save writes new nextActionText and routes',
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
      expect(row?.nextActionText, 'Draft proposal');
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

  group('ProcessToHandlers — next_action_text is on the user-action axis',
      () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets(
        'Waiting For (picker confirm) does NOT write next_action_text',
        (tester) async {
      // Orthogonality: routing to waitingFor sets intent + delegate, not
      // the user-action phrase. The dialog modifier (or a callsite-owned
      // setter) is the only path that writes next_action_text.
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

      final row = await db.todoDao.getTodo('na1');
      expect(row?.nextActionText, isNull,
          reason: 'waitingFor route must not synthesise a phrase');
    });

    testWidgets(
        'Next with the dialog excepted does NOT overwrite an existing '
        'next_action_text', (tester) async {
      final todo = await _insertTodo(
        db,
        id: 'na2',
        nextActionText: 'pre-existing phrase',
      );
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        except: const {ProcessAction.nextActionDialog},
      ));

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('na2');
      expect(row?.nextActionText, 'pre-existing phrase',
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
      // (sync/another device hard-deletes it). PowerSync's INSTEAD OF
      // triggers return 0 affected rows whether the write hit anything or
      // not, so the widget pre-checks existence and bails before firing
      // onAfterRoute (which would advance the cursor + record a phantom
      // routing record).
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

      await tester.tap(find.text('Discard'));
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
        'tapping Re-clarify… opens the ClarifyCard sub-flow on this item',
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

      // Sub-flow card is on screen, scaffolded with the Re-clarify app bar.
      expect(find.byType(ClarifyCard), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'Re-clarify'), findsOneWidget);
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
}
