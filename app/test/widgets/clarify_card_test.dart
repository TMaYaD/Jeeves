/// Widget tests for [ClarifyCard]'s routing behaviour (#293 regression).
///
/// `ClarifyCard` opts out of the default-on `nextActionDialog` modifier
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
import 'package:jeeves/widgets/clarify_card.dart';
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
  ClarifyMode mode = ClarifyMode.inbox,
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
        body: ClarifyCard(
          todoId: todo.id,
          mode: mode,
          onAfterRoute: onAfterRoute,
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(configureSqliteForTests);

  group('ClarifyCard — Next stays a one-tap route (#293)', () {
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

  group('ClarifyCard — title-as-action mirror is mode-aware', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets(
        'reclarify mode does NOT clobber an existing next_action_text',
        (tester) async {
      // Seed a previously-clarified row that already has a deliberate phrase.
      final now = DateTime.now();
      await db.into(db.todos).insert(TodosCompanion(
            id: const Value('rc-mirror-1'),
            title: const Value('Plan party'),
            clarified: const Value(true),
            intent: const Value('next'),
            nextActionText: const Value('Email guest list'),
            userId: const Value(_userId),
            createdAt: Value(now),
            updatedAt: Value(now),
          ));
      final todo = (await db.todoDao.getTodo('rc-mirror-1'))!;

      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        mode: ClarifyMode.reclarify,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('rc-mirror-1');
      expect(row?.nextActionText, 'Email guest list',
          reason: 'reclarify must not overwrite a deliberate phrase with the '
              'title');
      expect(row?.intent, 'next');
    });

    testWidgets(
        'reclarify mode DOES set next_action_text from title when previously '
        'empty', (tester) async {
      await _insertInboxTodo(
        db,
        id: 'rc-mirror-2',
        title: 'Decide on venue',
      );
      // Promote into a clarified-but-actionless state to mirror the
      // production scenario the guard targets.
      await db.todoDao
          .applyRouting('rc-mirror-2', to: RoutingKind.nextAction);
      final fresh = (await db.todoDao.getTodo('rc-mirror-2'))!;

      await tester.pumpWidget(_harness(
        db,
        todo: fresh,
        mode: ClarifyMode.reclarify,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('rc-mirror-2');
      expect(row?.nextActionText, 'Decide on venue',
          reason: 'an empty next_action_text in reclarify mode is filled from '
              'the title so the row leaves with a defined action');
    });
  });
}
