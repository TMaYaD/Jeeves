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
}) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      // Use a single-value stream so drift's StreamQueryStore (which leaves
      // a pending timer behind on dispose) is not subscribed to in tests.
      personTagsProvider.overrideWith((ref) => Stream.value(personTags)),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            ProcessToHandlers(
              todo: todo,
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

      await tester.pumpWidget(_harness(db, todo: todo));
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
  });

  group('ProcessToHandlers — nextActionDialog modifier', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets(
        'Next without modifier writes immediately; dialog never opens',
        (tester) async {
      final todo =
          await _insertTodo(db, id: 'nd1', nextActionText: 'pre-existing');
      await tester.pumpWidget(_harness(db, todo: todo));

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      // Dialog absent.
      expect(find.byType(NextActionDialog), findsNothing);
      final row = await db.todoDao.getTodo('nd1');
      expect(row?.intent, 'next');
    });

    testWidgets('Next with modifier opens prefilled dialog; cancel = no write',
        (tester) async {
      final todo = await _insertTodo(db, id: 'nd2', nextActionText: 'old');
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        include: const {ProcessAction.nextActionDialog},
      ));

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
        'Next with modifier — Save writes new nextActionText and routes',
        (tester) async {
      final todo = await _insertTodo(db, id: 'nd3');
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        include: const {ProcessAction.nextActionDialog},
      ));

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
      // 'call trixy for update' could be next action." Tapping Next must
      // not strip Trixy.
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
        'Next (no modifier) does NOT overwrite an existing next_action_text',
        (tester) async {
      final todo = await _insertTodo(
        db,
        id: 'na2',
        nextActionText: 'pre-existing phrase',
      );
      await tester.pumpWidget(_harness(db, todo: todo));

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
        'nextActionDialog modifier reports nextActionDialog (not next)',
        (tester) async {
      final todo = await _insertTodo(db, id: 'a2');
      final fired = <ProcessAction>[];
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        include: const {ProcessAction.nextActionDialog},
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
}
