/// Widget tests for [InboxClarifyCard]'s routing behaviour (#293 regression).
///
/// `InboxClarifyCard` opts out of the default-on `nextActionDialog` modifier
/// (`except: {nextActionDialog}`) because it supplies the next-action phrase
/// through the title-as-action coupling instead. Tapping Next must therefore
/// stay a one-tap route — no dialog — and still leave the row with a defined
/// `next_action_text`.
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
import 'package:jeeves/widgets/inbox_clarify_card.dart';
import 'package:jeeves/widgets/next_action_dialog.dart';
import 'package:jeeves/widgets/process_to_handlers.dart';

import '../test_helpers.dart';

const _userId = 'local';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

Future<Todo> _insertInboxTodo(
  GtdDatabase db, {
  required String id,
  String title = 'Buy milk',
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value(title),
        captureSource: const Value('manual'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  return (await db.todoDao.getTodo(id))!;
}

Widget _harness(
  GtdDatabase db, {
  required Todo todo,
  Future<void> Function(ProcessAction)? onAfterRoute,
}) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      // Static streams so drift's StreamQueryStore doesn't leave a pending
      // timer behind on dispose.
      taskDetailTodoProvider(todo.id).overrideWith((_) => Stream.value(todo)),
      personTagsProvider.overrideWith((_) => Stream.value(const <Tag>[])),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: InboxClarifyCard(
          todoId: todo.id,
          onAfterRoute: onAfterRoute,
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(configureSqliteForTests);

  group('InboxClarifyCard — Next stays a one-tap route (#293)', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets(
        'tapping Next does not open NextActionDialog and routes immediately',
        (tester) async {
      final todo = await _insertInboxTodo(db, id: 'x', title: 'Buy milk');
      final fired = <ProcessAction>[];
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        onAfterRoute: (action) async => fired.add(action),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      // Dialog modifier is excepted — no dialog pops.
      expect(find.byType(NextActionDialog), findsNothing);
      // The button reports plain `next`, not the dialog modifier.
      expect(fired, [ProcessAction.next]);

      final row = await db.todoDao.getTodo('x');
      expect(row?.intent, 'next');
      // Title-as-action coupling still mirrors the title into the phrase so
      // the row leaves the inbox with a defined action.
      expect(row?.nextActionText, 'Buy milk');
    });
  });
}
