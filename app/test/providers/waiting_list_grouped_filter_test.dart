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

    Future<List<String>> personNames() async {
      final grouped = await container.read(waitingListGroupedProvider.future);
      return grouped.keys.map((t) => t.name).toList();
    }

    expect(await personNames(), ['Alice', 'Bob']);

    container.read(tagFilterProvider.notifier).toggle('ctx');
    expect(await personNames(), ['Alice']);

    container.read(tagFilterProvider.notifier).clear();
    expect(await personNames(), ['Alice', 'Bob']);
  });
}
