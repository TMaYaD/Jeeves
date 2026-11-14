/// The upgrade gate of the time-named context tag conversion (#238), through the
/// real provider over a store rewound to the schema version before the column.
///
/// The gate once compared against a stale version (4) after the column moved to
/// v7, so every v4–v6 upgrade skipped conversion without a failing test.
@TestOn('!browser')
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/time_context.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/time_context_provider.dart';

import '../test_helpers.dart';

const _userId = 'local';

void main() {
  setUpAll(configureSqliteForTests);
  setUp(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  Future<int> reopenAtVersion(int? userVersion,
      {required void Function(GtdDatabase db, int converted) check}) async {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.close);
    final seed = GtdDatabase(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    await seed.into(seed.todos).insert(TodosCompanion(
        id: const Value('o1'),
        title: const Value('Plan the offsite'),
        userId: const Value(_userId),
        createdAt: Value(DateTime.now())));
    await seedCurrentAction(seed,
        outcomeId: 'o1', text: 'book a room', userId: _userId);
    await seed.into(seed.tags).insert(TagsCompanion(
        id: const Value('t-morning'),
        name: const Value('@morning'),
        type: const Value('context'),
        userId: const Value(_userId)));
    await seed.into(seed.todoTags).insert(TodoTagsCompanion(
        id: const Value('o1-t-morning'),
        todoId: const Value('o1'),
        tagId: const Value('t-morning'),
        userId: const Value(_userId)));
    await seed.customStatement('PRAGMA user_version = ${userVersion ?? 0}');
    await seed.close();

    final reopened = GtdDatabase(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    addTearDown(reopened.close);
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(reopened),
      domainStoreRebuildProvider.overrideWith((ref) async => 0),
    ]);
    addTearDown(container.dispose);
    final converted =
        await container.read(timeContextTagConversionProvider.future);
    check(reopened, converted);
    return converted;
  }

  for (final from in [4, 5, 6]) {
    test('an upgrade from v$from converts "@morning" onto the Action',
        () async {
      GtdDatabase? opened;
      await reopenAtVersion(from, check: (db, converted) {
        opened = db;
        expect(converted, 1);
      });
      final db = opened!;
      final action = (await db.actionDao.getCurrentAction('o1'))!;
      expect(TimeContext.tryParse(action.timeContext), isNotNull);
      expect(await db.select(db.todoTags).get(), isEmpty,
          reason: 'the Outcome-tag link is removed');
      expect(await db.select(db.tags).get(), hasLength(1),
          reason: 'the Tag row is never deleted');
    });
  }

  test('a store already at the current version converts nothing', () async {
    await reopenAtVersion(timeContextSchemaVersion,
        check: (db, converted) => expect(converted, 0));
  });
}
