/// `TodoDao.watchOffUpNextPlanningCandidates` (#696): the Outcomes the plan
/// step's search offers below its Up Next matches.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import '../test_helpers.dart';

const _userId = 'test-user';

Future<void> _insert(
  GtdDatabase db,
  String id, {
  String intent = 'next',
  bool clarified = true,
  bool withAction = false,
  bool personBlocked = false,
  String? doneAt,
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Outcome $id'),
        clarified: Value(clarified),
        intent: Value(intent),
        doneAt: Value(doneAt),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  if (withAction) {
    await seedCurrentAction(db,
        outcomeId: id, text: 'work on $id', userId: _userId);
  }
  if (personBlocked) {
    await db.into(db.tags).insert(TagsCompanion(
          id: Value('ptag-$id'),
          name: Value('Trixy-$id'),
          type: const Value('person'),
          userId: const Value(_userId),
        ));
    await db.into(db.todoTags).insert(TodoTagsCompanion(
          id: Value('tt-$id'),
          todoId: Value(id),
          tagId: Value('ptag-$id'),
          userId: const Value(_userId),
        ));
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  setUp(() => db = GtdDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<Set<String>> ids() async => (await db.todoDao
          .watchOffUpNextPlanningCandidates()
          .first)
      .map((t) => t.id)
      .toSet();

  test('holds Someday and Waiting-For-only Outcomes, nothing else', () async {
    await _insert(db, 'next', withAction: true);
    await _insert(db, 'next-chase', withAction: true, personBlocked: true);
    await _insert(db, 'someday', intent: 'maybe');
    await _insert(db, 'waiting', personBlocked: true);
    await _insert(db, 'done', doneAt: DateTime.now().toIso8601String());
    await _insert(db, 'done-someday',
        intent: 'maybe', doneAt: DateTime.now().toIso8601String());
    await _insert(db, 'trash', intent: 'trash');
    await _insert(db, 'unclarified', intent: 'maybe', clarified: false);

    expect(await ids(), {'someday', 'waiting'});
  });

  test('an Outcome leaves the set when its person tag is removed', () async {
    await _insert(db, 'waiting', personBlocked: true);
    expect(await ids(), {'waiting'});

    // Without the person tag an actionless Next Outcome is back on Next.
    await db.customStatement("DELETE FROM todo_tags WHERE todo_id = 'waiting'");
    expect(await ids(), isEmpty);
  });
}
