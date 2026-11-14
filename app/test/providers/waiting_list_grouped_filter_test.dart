import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/tag_filter_provider.dart';

import '../test_helpers.dart';

const _userId = 'test-user';

Future<void> _insertTag(
  GtdDatabase db,
  String id,
  String name,
  String type,
) =>
    db.tagDao.upsertTag(TagsCompanion(
      id: Value(id),
      name: Value(name),
      type: Value(type),
      userId: const Value(_userId),
    ));

Future<void> _insertTodo(GtdDatabase db, String id) {
  final now = DateTime.now();
  return db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value(id),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
}

void main() {
  setUpAll(configureSqliteForTests);

  test('waitingListGroupedProvider follows the tag filter', () async {
    final db = GtdDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _insertTag(db, 'ctx', 'errand', 'context');
    await _insertTag(db, 'alice', 'Alice', 'person');
    await _insertTag(db, 'bob', 'Bob', 'person');
    await _insertTodo(db, 'a');
    await _insertTodo(db, 'b');
    await db.tagDao.assignTag('a', 'alice', _userId);
    await db.tagDao.assignTag('a', 'ctx', _userId);
    await db.tagDao.assignTag('b', 'bob', _userId);

    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    // Hold a listener so the stream stays subscribed across filter changes.
    final subscription = container.listen(
      waitingListGroupedProvider,
      (_, _) {},
    );
    addTearDown(subscription.close);

    // Poll the latest emission until it matches; drift streams deliver on
    // real async turns, so a short delay lets re-subscription settle.
    Future<void> expectPeople(List<String> expected) async {
      List<String>? actual;
      for (var attempt = 0; attempt < 100; attempt++) {
        final grouped = container.read(waitingListGroupedProvider).value;
        actual = grouped?.keys.map((t) => t.name).toList();
        if (actual != null && actual.join(',') == expected.join(',')) return;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(actual, expected);
    }

    await expectPeople(['Alice', 'Bob']);

    container.read(tagFilterProvider.notifier).toggle('ctx');
    await expectPeople(['Alice']);

    container.read(tagFilterProvider.notifier).clear();
    await expectPeople(['Alice', 'Bob']);
  });
}
