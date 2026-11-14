/// Journey for #889: the Waiting For page follows the sticky tag filter.
///
/// Real in-memory store, real `waitingListGroupedProvider`, real
/// `ActiveFilterBar`. The store is staged in `setUp` (outside FakeAsync) and
/// the drift streams are advanced with `settleWithRealAsync`, per
/// docs/TESTING.md.
@TestOn('!browser')
library;

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/tag_filter_provider.dart';
import 'package:jeeves/screens/waiting_for/waiting_for_screen.dart';
import 'package:jeeves/widgets/outcome_row.dart';

import '../helpers/settle.dart';
import '../test_helpers.dart';

const _userId = 'test-user';

Future<void> _insertTag(GtdDatabase db, String id, String name, String type) =>
    db.tagDao.upsertTag(TagsCompanion(
      id: Value(id),
      name: Value(name),
      type: Value(type),
      userId: const Value(_userId),
    ));

Future<void> _insertTodo(GtdDatabase db, String id, String title) {
  final now = DateTime.now();
  return db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value(title),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;

  setUp(() async {
    db = GtdDatabase(NativeDatabase.memory());
    await _insertTag(db, 'ctx', 'errand', 'context');
    await _insertTag(db, 'alice', 'Alice', 'person');
    await _insertTag(db, 'bob', 'Bob', 'person');
    await _insertTodo(db, 'a', 'Send the contract');
    await _insertTodo(db, 'b', 'Return the drill');
    await db.tagDao.assignTag('a', 'alice', _userId);
    await db.tagDao.assignTag('a', 'ctx', _userId);
    await db.tagDao.assignTag('b', 'bob', _userId);
  });

  testWidgets('selecting a tag narrows the page; Clear all restores it',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(home: WaitingForScreen()),
      ),
    );
    await settleWithRealAsync(tester, rounds: 5);

    expect(find.byType(OutcomeRow), findsNWidgets(2));
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.byKey(const Key('active_filter_clear_all')), findsNothing);

    // The drawer's chip tap is a toggle on the shared filter provider.
    final container =
        ProviderScope.containerOf(tester.element(find.byType(WaitingForScreen)));
    container.read(tagFilterProvider.notifier).toggle('ctx');
    await settleWithRealAsync(tester, rounds: 5);

    expect(find.byType(OutcomeRow), findsOneWidget);
    expect(find.text('Send the contract'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Return the drill'), findsNothing);
    expect(find.text('Bob'), findsNothing);

    await tester.tap(find.byKey(const Key('active_filter_clear_all')));
    await settleWithRealAsync(tester, rounds: 5);

    expect(find.byType(OutcomeRow), findsNWidgets(2));
    expect(find.text('Return the drill'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.byKey(const Key('active_filter_clear_all')), findsNothing);

    // Dispose in the real zone so drift's subscription cleanup can finish.
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await pumpEventQueue();
      await db.close();
    });
  });
}
