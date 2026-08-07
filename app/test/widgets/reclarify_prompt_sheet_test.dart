/// Widget tests for [ReclarifyPromptSheet] (issue #469).
///
/// The sheet is only a shell around the canonical [ProcessToHandlers] bar, so
/// these tests pin the sheet-specific behaviour: the four ruled verdicts render
/// (no Trash), each routes correctly against a real [GtdDatabase], "More to
/// do…" opens the next-action dialog empty, and dismissing writes nothing.
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/tags_provider.dart';
import 'package:jeeves/widgets/next_action_dialog.dart';
import 'package:jeeves/widgets/process_to_handlers.dart';
import 'package:jeeves/widgets/reclarify_prompt_sheet.dart';

import '../test_helpers.dart';

const _userId = 'local';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

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

Future<void> _insertPersonTag(
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
}

Tag _personTag(String id, String name) =>
    Tag(id: id, name: name, type: 'person', userId: _userId);

/// Pumps a screen with a single button that floats the sheet for [todo] and
/// records the resolved [ProcessAction] (or null on dismiss).
Future<List<ProcessAction?>> _pumpAndOpen(
  WidgetTester tester,
  GtdDatabase db, {
  required Todo todo,
  List<Tag> personTags = const [],
}) async {
  final results = <ProcessAction?>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        personTagsProvider.overrideWith((ref) => Stream.value(personTags)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  results.add(await ReclarifyPromptSheet.show(context, todo));
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return results;
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  setUp(() => db = _openInMemory());
  tearDown(() async => db.close());

  testWidgets('renders the four ruled verdicts, header, and no Trash',
      (tester) async {
    final todo = await _insertTodo(db, id: 'r1');
    await _pumpAndOpen(tester, db, todo: todo);

    expect(find.byType(ReclarifyPromptSheet), findsOneWidget);
    expect(find.text('Action complete'), findsOneWidget);
    expect(find.text('Outcome achieved'), findsOneWidget);
    expect(find.text('More to do…'), findsOneWidget);
    expect(find.text('Waiting on someone…'), findsOneWidget);
    expect(find.text('Defer to Someday'), findsOneWidget);
    // Trash is not one of the ruled verdicts.
    expect(find.text('Trash'), findsNothing);
    // The Action-Done vs Outcome-Done disambiguation: no plain "Done".
    expect(find.text('Done'), findsNothing);
  });

  testWidgets('Outcome achieved records Completion and resolves done',
      (tester) async {
    final todo = await _insertTodo(db, id: 'r2');
    final results = await _pumpAndOpen(tester, db, todo: todo);

    await tester.tap(find.text('Outcome achieved'));
    await tester.pumpAndSettle();

    final row = await db.todoDao.getTodo('r2');
    expect(row?.doneAt, isNotNull);
    expect(row?.lastClarifiedAt, isNotNull);
    expect(results, [ProcessAction.done]);
  });

  testWidgets(
      'More to do… opens the dialog empty; saving creates a current Action',
      (tester) async {
    final todo = await _insertTodo(db, id: 'r3');
    final results = await _pumpAndOpen(tester, db, todo: todo);

    await tester.tap(find.text('More to do…'));
    await tester.pumpAndSettle();

    // The cursor was cleared by completeCurrentAction, so the dialog opens
    // empty — nothing is prefilled.
    expect(find.byType(NextActionDialog), findsOneWidget);
    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byType(NextActionDialog),
        matching: find.byType(TextField),
      ),
    );
    expect(field.controller?.text, '');

    await tester.enterText(
      find.descendant(
        of: find.byType(NextActionDialog),
        matching: find.byType(TextField),
      ),
      'Draft the outline',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final current = await db.actionDao.getCurrentAction('r3');
    expect(current?.actionText, 'Draft the outline');
    final row = await db.todoDao.getTodo('r3');
    expect(row?.intent, 'next');
    expect(row?.doneAt, isNull);
    expect(row?.lastClarifiedAt, isNotNull);
    expect(results, [ProcessAction.nextActionDialog]);
  });

  testWidgets('More to do… with a blank save falls back to the title (#691)',
      (tester) async {
    // The sheet is a shell around the shared bar, so it inherits the
    // title-as-action fallback: the user who knows there is more to
    // do but cannot name it is not held on the sheet. It matters most here —
    // completeCurrentAction has just left the Outcome Actionless, which is the
    // state that re-arms the re-clarification queue with no freshness gate.
    final todo = await _insertTodo(db, id: 'r4', title: 'Ship the thing');
    final results = await _pumpAndOpen(tester, db, todo: todo);

    await tester.tap(find.text('More to do…'));
    await tester.pumpAndSettle();
    // Save without entering text.
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect((await db.actionDao.getCurrentAction('r4'))?.actionText,
        'Ship the thing');
    final row = await db.todoDao.getTodo('r4');
    expect(row?.intent, 'next');
    expect(row?.doneAt, isNull,
        reason: 'more to do is not an Outcome achievement');
    expect(row?.lastClarifiedAt, isNotNull);
    // Still not a `done` verdict — the focus screen keys "All done for today!"
    // on that specifically, and this resolution must not claim it.
    expect(results, [ProcessAction.nextActionDialog]);
  });

  testWidgets('Waiting on someone… delegates and resolves waitingFor',
      (tester) async {
    final todo = await _insertTodo(db, id: 'r5');
    await _insertPersonTag(db, id: 'alice', name: 'Alice');
    final results = await _pumpAndOpen(
      tester,
      db,
      todo: todo,
      personTags: [_personTag('alice', 'Alice')],
    );

    await tester.tap(find.text('Waiting on someone…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alice'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pumpAndSettle();

    expect(await db.todoDao.getPersonTagIdsForTodo('r5'), contains('alice'));
    final row = await db.todoDao.getTodo('r5');
    expect(row?.intent, 'next');
    expect(row?.lastClarifiedAt, isNotNull);
    expect(results, [ProcessAction.waitingFor]);
  });

  testWidgets('Defer to Someday sets intent maybe and resolves someday',
      (tester) async {
    final todo = await _insertTodo(db, id: 'r6');
    final results = await _pumpAndOpen(tester, db, todo: todo);

    await tester.tap(find.text('Defer to Someday'));
    await tester.pumpAndSettle();

    final row = await db.todoDao.getTodo('r6');
    expect(row?.intent, 'maybe');
    expect(row?.lastClarifiedAt, isNotNull);
    expect(results, [ProcessAction.someday]);
  });

  testWidgets('dismissing the sheet writes nothing and resolves null',
      (tester) async {
    final todo = await _insertTodo(db, id: 'r7');
    final results = await _pumpAndOpen(tester, db, todo: todo);

    // Tap the modal barrier above the sheet to dismiss it.
    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();

    expect(find.byType(ReclarifyPromptSheet), findsNothing);
    expect(await db.actionDao.getCurrentAction('r7'), isNull);
    final row = await db.todoDao.getTodo('r7');
    expect(row?.intent, 'next', reason: 'dismiss must not route');
    expect(row?.doneAt, isNull);
    expect(row?.lastClarifiedAt, isNull);
    expect(results, [null]);
  });
}
