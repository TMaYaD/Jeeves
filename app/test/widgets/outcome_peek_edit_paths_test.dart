/// Edit paths of the Daily Planning Outcome peek that need the real stores:
/// context tags, Waiting For people, due date, the Plan, and reconciliation of
/// an untouched title / notes with a later row update.
///
/// Providers are not stubbed here, so live Drift watches are running: pump
/// fixed durations, never `pumpAndSettle` while a stream is open (TESTING.md).
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/widgets/outcome_peek_sheet.dart';

import '../test_helpers.dart';

const _userId = 'local';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

Future<Todo> _seedOutcome(
  GtdDatabase db,
  String id, {
  String title = 'Ship the release',
  String? notes,
  DateTime? dueDate,
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value(title),
        notes: Value(notes),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
        dueDate: Value(dueDate),
      ));
  return (await db.todoDao.getTodo(id))!;
}

Widget _harness(GtdDatabase db, Todo todo) {
  return ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => OutcomePeekSheet.show(context, todo),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<Todo> _row(WidgetTester tester, GtdDatabase db, String id) async =>
    (await tester.runAsync(() => db.todoDao.getTodo(id)))!;

/// Lets writes land and the live watches re-emit without settling.
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() => pumpEventQueue());
  // Long enough for a bottom sheet to finish sliding in (about 250 ms).
  await tester.pump(const Duration(milliseconds: 400));
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump(const Duration(milliseconds: 400));
}

/// Unmounts the tree inside the test body. The binding would otherwise do it
/// after the body, where Drift's stream-close timer is left pending.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _open(WidgetTester tester) async {
  // Tall enough that the sheet's lower controls (Done, Plan) are on screen.
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.tap(find.text('open'));
  await _settle(tester);
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  setUp(() => db = _openInMemory());
  tearDown(() async => db.close());

  testWidgets('adding a context tag assigns it and does not stamp',
      (tester) async {
    final todo = await _seedOutcome(db, 'c1');
    await db.tagDao.upsertTag(const TagsCompanion(
      id: Value('ctx-home'),
      name: Value('home'),
      type: Value('context'),
      userId: Value(_userId),
    ));
    final before = await _row(tester, db, 'c1');
    await tester.pumpWidget(_harness(db, todo));
    await _open(tester);

    await tester.tap(find.byKey(const Key('outcome_peek_add_context')));
    await _settle(tester);
    await tester.tap(find.text('@home').last);
    await _settle(tester);

    final assigned = await tester.runAsync(() => (db.select(db.todoTags)
          ..where((t) => t.todoId.equals('c1')))
        .get());
    expect(assigned!.map((r) => r.tagId), ['ctx-home']);
    expect((await _row(tester, db, 'c1')).lastClarifiedAt,
        before.lastClarifiedAt);
    await _unmount(tester);
  });

  testWidgets('a name no tag has offers Add, which creates and applies it',
      (tester) async {
    final todo = await _seedOutcome(db, 'c2');
    final before = await _row(tester, db, 'c2');
    await tester.pumpWidget(_harness(db, todo));
    await _open(tester);

    await tester.tap(find.byKey(const Key('outcome_peek_add_context')));
    await _settle(tester);
    await tester.enterText(
        find.byKey(const Key('tag_cloud_find_field')), '@Errands');
    await _settle(tester);
    expect(find.text('Add "Errands"'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tag_cloud_add_tag')));
    await _settle(tester);

    final created = await tester.runAsync(() => (db.select(db.tags)
          ..where((t) => t.name.equals('Errands') & t.type.equals('context')))
        .get());
    expect(created, hasLength(1));
    final assigned = await tester.runAsync(() => (db.select(db.todoTags)
          ..where((t) => t.todoId.equals('c2')))
        .get());
    expect(assigned!.map((r) => r.tagId), [created!.single.id]);
    expect((await _row(tester, db, 'c2')).lastClarifiedAt,
        before.lastClarifiedAt);
    await _unmount(tester);
  });

  testWidgets('choosing a person under Waiting for assigns and stamps',
      (tester) async {
    final todo = await _seedOutcome(db, 'p1');
    await db.tagDao.upsertTag(const TagsCompanion(
      id: Value('person-alice'),
      name: Value('Alice'),
      type: Value('person'),
      userId: Value(_userId),
    ));
    await tester.pumpWidget(_harness(db, todo));
    await _open(tester);
    expect(find.text('Nobody'), findsOneWidget);

    await tester.tap(find.byKey(const Key('outcome_peek_delegates')));
    await _settle(tester);
    await tester.tap(find.text('Alice'));
    await tester.pump();
    await tester.tap(find.text('Done'));
    await _settle(tester);

    final ids = await tester
        .runAsync(() => db.tagDao.getPersonTagIdsForTodo('p1'));
    expect(ids, {'person-alice'});
    expect((await _row(tester, db, 'p1')).lastClarifiedAt, isNotNull);
    expect(find.text('Nobody'), findsNothing);
    await _unmount(tester);
  });

  testWidgets('the due chip sets a date and the clear control removes it',
      (tester) async {
    final todo = await _seedOutcome(db, 'd1');
    await tester.pumpWidget(_harness(db, todo));
    await _open(tester);
    expect(find.byKey(const Key('outcome_peek_due_clear')), findsNothing);

    await tester.tap(find.byKey(const Key('outcome_peek_due')));
    await _settle(tester);
    await tester.tap(find.text('OK'));
    await _settle(tester);

    expect((await _row(tester, db, 'd1')).dueDate, isNotNull);
    expect(find.byKey(const Key('outcome_peek_due_clear')), findsOneWidget);

    await tester.tap(find.byKey(const Key('outcome_peek_due_clear')));
    await _settle(tester);

    expect((await _row(tester, db, 'd1')).dueDate, isNull);
    expect(find.byKey(const Key('outcome_peek_due_clear')), findsNothing);
    await _unmount(tester);
  });

  testWidgets('a Plan edit from the peek adds a planned Action',
      (tester) async {
    final todo = await _seedOutcome(db, 'a1');
    await tester.pumpWidget(_harness(db, todo));
    await _open(tester);

    await tester.ensureVisible(find.byKey(const Key('plan_add_trigger')));
    await tester.tap(find.byKey(const Key('plan_add_trigger')));
    await _settle(tester);
    await tester.enterText(
        find.byKey(const Key('plan_action_text')), 'Call the printer');
    await tester.pump();
    await tester.tap(find.byKey(const Key('plan_action_confirm')));
    await _settle(tester);

    final actions = await tester.runAsync(() => (db.select(db.actions)
          ..where((a) => a.outcomeId.equals('a1')))
        .get());
    expect(actions!.map((a) => a.actionText), ['Call the printer']);
    expect((await _row(tester, db, 'a1')).lastClarifiedAt, isNotNull);
    await _unmount(tester);
  });

  testWidgets('an untouched title and notes follow a later row update',
      (tester) async {
    final todo = await _seedOutcome(db, 'r1', title: 'Old', notes: 'Old notes');
    await tester.pumpWidget(_harness(db, todo));
    await _open(tester);

    await tester.runAsync(() => (db.update(db.todos)
          ..where((t) => t.id.equals('r1')))
        .write(const TodosCompanion(
      title: Value('Renamed elsewhere'),
      notes: Value('Notes changed elsewhere'),
    )));
    await _settle(tester);

    expect(find.text('Renamed elsewhere'), findsOneWidget);
    expect(find.text('Notes changed elsewhere'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('a title being edited is not overwritten by a row update',
      (tester) async {
    final todo = await _seedOutcome(db, 'r2', title: 'Old');
    await tester.pumpWidget(_harness(db, todo));
    await _open(tester);

    await tester.enterText(
        find.byKey(const Key('outcome_peek_title')), 'Typing now');
    await tester.runAsync(() => (db.update(db.todos)
          ..where((t) => t.id.equals('r2')))
        .write(const TodosCompanion(title: Value('Renamed elsewhere'))));
    await _settle(tester);

    expect(find.text('Typing now'), findsOneWidget);
    expect(find.text('Renamed elsewhere'), findsNothing);
    await _unmount(tester);
  });
}
