/// The Time context chip and sheet (#238) on the Daily Planning Outcome peek,
/// against the real stores. Pump fixed durations, never `pumpAndSettle` while a
/// stream is open (TESTING.md).
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

Future<Todo> _seedOutcome(GtdDatabase db, String id,
    {bool withAction = true}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: const Value('Ship the release'),
        clarified: const Value(true),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  if (withAction) {
    await seedCurrentAction(db,
        outcomeId: id, text: 'do it', userId: _userId);
  }
  return (await db.todoDao.getTodo(id))!;
}

Widget _harness(GtdDatabase db, Todo todo) => ProviderScope(
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

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump(const Duration(milliseconds: 400));
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.tap(find.text('open'));
  await _settle(tester);
}

Future<String?> _stored(WidgetTester tester, GtdDatabase db) async {
  final row = await tester.runAsync(() => (db.select(db.actions)
        ..where((a) => a.role.equals('current')))
      .getSingle());
  return row!.timeContext;
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  setUp(() => db = GtdDatabase(NativeDatabase.memory()));
  tearDown(() async => db.close());

  testWidgets('setting weekdays saves, then Clear removes, without stamping',
      (tester) async {
    final todo = await _seedOutcome(db, 't1');
    await tester.pumpWidget(_harness(db, todo));
    await _open(tester);

    await tester.tap(find.byKey(const Key('time_context_chip')));
    await _settle(tester);
    expect(find.byKey(const Key('time_context_clear')), findsNothing);
    await tester.tap(find.byKey(const Key('time_context_day_2')));
    await tester.tap(find.byKey(const Key('time_context_day_4')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('time_context_save')));
    await _settle(tester);

    expect(await _stored(tester, db), '{"days":[2,4]}');
    expect(find.text('Tue, Thu'), findsOneWidget);
    final stamped = (await tester.runAsync(() => db.todoDao.getTodo('t1')))!;
    expect(stamped.lastClarifiedAt, todo.lastClarifiedAt);

    await tester.tap(find.byKey(const Key('time_context_chip')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('time_context_clear')));
    await _settle(tester);
    expect(await _stored(tester, db), isNull);

    await _unmount(tester);
  });

  testWidgets('Save is disabled until something is set', (tester) async {
    final todo = await _seedOutcome(db, 't2');
    await tester.pumpWidget(_harness(db, todo));
    await _open(tester);

    await tester.tap(find.byKey(const Key('time_context_chip')));
    await _settle(tester);
    final save = tester
        .widget<FilledButton>(find.byKey(const Key('time_context_save')));
    expect(save.onPressed, isNull);

    await _unmount(tester);
  });

  testWidgets('an unreadable stored value shows and can be cleared',
      (tester) async {
    final todo = await _seedOutcome(db, 't3');
    await db.customStatement("UPDATE actions SET time_context = 'garbage'");
    await tester.pumpWidget(_harness(db, todo));
    await _open(tester);

    expect(find.text('Unreadable'), findsOneWidget);
    await tester.tap(find.byKey(const Key('time_context_chip')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('time_context_clear')));
    await _settle(tester);
    expect(await _stored(tester, db), isNull);

    await _unmount(tester);
  });

  testWidgets('an Actionless Outcome shows no chip', (tester) async {
    final todo = await _seedOutcome(db, 't4', withAction: false);
    await tester.pumpWidget(_harness(db, todo));
    await _open(tester);

    expect(find.byKey(const Key('time_context_chip')), findsNothing);

    await _unmount(tester);
  });

  Future<void> _replaceCurrentWhileOpen(WidgetTester tester) async {
    await tester.runAsync(() async {
      await db.actionDao
          .supersedeCurrentAction('t5', newActionText: 'the successor');
      await db.customStatement(
          "UPDATE actions SET time_context = '{\"days\":[1]}' "
          "WHERE role = 'current'");
    });
  }

  Future<List<String?>> _storedByRole(WidgetTester tester) async {
    final rows = await tester.runAsync(() => (db.select(db.actions)
          ..orderBy([(a) => OrderingTerm.asc(a.createdAt)]))
        .get());
    return [for (final r in rows!) r.timeContext];
  }

  testWidgets('Save after the Action was replaced leaves the successor alone',
      (tester) async {
    final todo = await _seedOutcome(db, 't5');
    await tester.pumpWidget(_harness(db, todo));
    await _open(tester);

    await tester.tap(find.byKey(const Key('time_context_chip')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('time_context_day_2')));
    await tester.pump();
    await _replaceCurrentWhileOpen(tester);
    await tester.tap(find.byKey(const Key('time_context_save')));
    await _settle(tester);

    expect(await _storedByRole(tester), [null, '{"days":[1]}']);

    await _unmount(tester);
  });

  testWidgets('Clear after the Action was replaced leaves the successor alone',
      (tester) async {
    final todo = await _seedOutcome(db, 't5');
    await db.customStatement(
        "UPDATE actions SET time_context = '{\"days\":[2]}'");
    await tester.pumpWidget(_harness(db, todo));
    await _open(tester);

    await tester.tap(find.byKey(const Key('time_context_chip')));
    await _settle(tester);
    await _replaceCurrentWhileOpen(tester);
    await tester.tap(find.byKey(const Key('time_context_clear')));
    await _settle(tester);

    expect(await _storedByRole(tester), ['{"days":[2]}', '{"days":[1]}']);

    await _unmount(tester);
  });
}
