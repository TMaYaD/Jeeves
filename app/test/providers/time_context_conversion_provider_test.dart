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
import 'package:jeeves/database/time_context_tag_conversion.dart';
import 'package:jeeves/models/time_context.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/time_context_provider.dart';

import '../test_helpers.dart';

const _userId = 'local';

void main() {
  setUpAll(configureSqliteForTests);
  setUp(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  /// Strips what the v7 step adds, leaving the schema a v6 build wrote.
  Future<void> rewindToVersion6(GtdDatabase db) async {
    await db.customStatement('DROP TABLE local_migration_markers');
    await db.customStatement('ALTER TABLE actions DROP COLUMN time_context');
    await db.customStatement('PRAGMA user_version = 6');
  }

  Future<int> reopenAtVersion(int? userVersion,
      {bool markerPresent = false,
      required void Function(GtdDatabase db, int converted) check}) async {
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
    // A fresh store carries the marker from onCreate; an older store has
    // neither the marker table nor the column, so the open below must run the
    // real v7 migration step to create them.
    if (!markerPresent) {
      await rewindToVersion6(seed);
    }
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
    await reopenAtVersion(7,
        markerPresent: true,
        check: (db, converted) => expect(converted, 0));
  });

  test(
      'an interrupted upgrade (v6 -> v7 committed, conversion not) converts '
      'once on the next open, and the marker then blocks later conversions',
      () async {
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
    await rewindToVersion6(seed);
    await seed.close();

    // The upgrade runs and commits; the process stops before the conversion.
    final upgraded = GtdDatabase(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    await upgraded.customSelect('SELECT 1').get();
    expect(
        (raw.select('PRAGMA user_version').first.values.first as int), 12,
        reason: 'the schema upgrade committed');
    expect(await upgraded.select(upgraded.localMigrationMarkers).get(),
        isEmpty,
        reason: 'the v7 step created the marker table; nothing marked it yet');
    expect(await upgraded.select(upgraded.todoTags).get(), hasLength(1),
        reason: 'the conversion did not run');
    await upgraded.close();

    Future<int> openAndConvert() async {
      final db = GtdDatabase(
          NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
      addTearDown(db.close);
      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        domainStoreRebuildProvider.overrideWith((ref) async => 0),
      ]);
      addTearDown(container.dispose);
      final converted =
          await container.read(timeContextTagConversionProvider.future);
      await db.close();
      return converted;
    }

    expect(await openAndConvert(), 1, reason: 'first open after interruption');

    // Between opens, a new eligible link appears (e.g. synced from another
    // device). Only the persisted marker can make the next open skip it.
    final between = GtdDatabase(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    final markers = await between.select(between.localMigrationMarkers).get();
    expect(markers.map((m) => m.name), [timeContextConversionMarkerName],
        reason: 'the marker persisted with the conversion');
    final action = (await between.actionDao.getCurrentAction('o1'))!;
    expect(TimeContext.tryParse(action.timeContext), isNotNull);
    expect(await between.select(between.tags).get(), hasLength(1));
    // A second Outcome whose current Action has no TimeContext: unlike o1
    // (already converted, so skipped on its own), this link is eligible.
    await between.into(between.todos).insert(TodosCompanion(
        id: const Value('o2'),
        title: const Value('Book travel'),
        userId: const Value(_userId),
        createdAt: Value(DateTime.now())));
    await seedCurrentAction(between,
        outcomeId: 'o2', text: 'compare flights', userId: _userId);
    expect((await between.actionDao.getCurrentAction('o2'))!.timeContext,
        isNull);
    await between.into(between.todoTags).insert(TodoTagsCompanion(
        id: const Value('o2-t-morning'),
        todoId: const Value('o2'),
        tagId: const Value('t-morning'),
        userId: const Value(_userId)));
    await between.close();

    expect(await openAndConvert(), 0, reason: 'the marker blocks a re-run');
    final after = GtdDatabase(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    addTearDown(after.close);
    final links = await after.select(after.todoTags).get();
    expect(links.map((l) => l.id), ['o2-t-morning'],
        reason: 'the eligible link was left alone because of the marker');
    expect((await after.actionDao.getCurrentAction('o2'))!.timeContext,
        isNull,
        reason: 'the marker stopped the conversion from touching o2');
  });
}
