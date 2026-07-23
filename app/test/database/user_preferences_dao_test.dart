import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import '../test_helpers.dart';

const _userId = 'test-user';

GtdDatabase _openDb() => GtdDatabase(NativeDatabase.memory());

void main() {
  setUpAll(configureSqliteForTests);

  group('UserPreferencesDao', () {
    late GtdDatabase db;

    setUp(() {
      db = _openDb();
    });
    tearDown(() => db.close());

    test('set creates a row', () async {
      await db.userPreferencesDao.set(_userId, 'my_key', '"hello"');
      final rows = await db.customSelect(
        'SELECT "key", value FROM user_preferences WHERE user_id = ?',
        variables: [Variable.withString(_userId)],
      ).get();
      expect(rows.length, 1);
      expect(rows.first.read<String>('key'), 'my_key');
      expect(rows.first.read<String?>('value'), '"hello"');
    });

    test('set upserts: second write updates value and updated_at, preserves id', () async {
      await db.userPreferencesDao.set(_userId, 'k', '"v1"');
      final before = await db.customSelect(
        'SELECT id, value, updated_at FROM user_preferences WHERE user_id = ? AND "key" = ?',
        variables: [Variable.withString(_userId), Variable.withString('k')],
      ).get();
      final originalId = before.first.read<String>('id');
      final originalUpdatedAt = before.first.read<String>('updated_at');

      await Future<void>.delayed(const Duration(milliseconds: 10));
      await db.userPreferencesDao.set(_userId, 'k', '"v2"');
      final after = await db.customSelect(
        'SELECT id, value, updated_at FROM user_preferences WHERE user_id = ? AND "key" = ?',
        variables: [Variable.withString(_userId), Variable.withString('k')],
      ).get();

      expect(after.length, 1);
      expect(after.first.read<String>('id'), originalId);
      expect(after.first.read<String?>('value'), '"v2"');
      expect(
        after.first.read<String>('updated_at').compareTo(originalUpdatedAt),
        greaterThan(0),
        reason: 'updated_at should advance on upsert',
      );
    });

    test('get returns value; null when absent; null when tombstoned', () async {
      expect(await db.userPreferencesDao.get(_userId, 'missing'), isNull);

      await db.userPreferencesDao.set(_userId, 'k', '"v"');
      expect(await db.userPreferencesDao.get(_userId, 'k'), '"v"');

      await db.userPreferencesDao.set(_userId, 'k', null);
      expect(await db.userPreferencesDao.get(_userId, 'k'), isNull);
    });

    test('getAll excludes tombstones', () async {
      await db.userPreferencesDao.set(_userId, 'a', '"1"');
      await db.userPreferencesDao.set(_userId, 'b', null); // tombstone
      await db.userPreferencesDao.set(_userId, 'c', '"3"');

      final all = await db.userPreferencesDao.getAll(_userId);
      expect(all.keys, containsAll(['a', 'c']));
      expect(all.containsKey('b'), isFalse);
    });

    test('watchAll emits all rows including tombstones', () async {
      await db.userPreferencesDao.set(_userId, 'x', '"val"');
      await db.userPreferencesDao.set(_userId, 'y', null);

      final rows = await db.userPreferencesDao.watchAll(_userId).first;
      expect(rows.length, 2);
      final keys = rows.map((r) => r.key).toSet();
      expect(keys, containsAll(['x', 'y']));
    });

    test('watch emits null on tombstone and absence', () async {
      // Absent → null
      expect(await db.userPreferencesDao.watch(_userId, 'k').first, isNull);

      await db.userPreferencesDao.set(_userId, 'k', '"v"');
      await db.userPreferencesDao.set(_userId, 'k', null); // tombstone
      expect(await db.userPreferencesDao.watch(_userId, 'k').first, isNull);
    });

    test('setAll upserts all entries', () async {
      await db.userPreferencesDao.setAll(_userId, {
        'a': '"1"',
        'b': '2',
        'c': null,
      });

      final all = await db.userPreferencesDao.getAll(_userId);
      expect(all['a'], '"1"');
      expect(all['b'], '2');
      expect(all.containsKey('c'), isFalse); // tombstone excluded
    });

    test('rows for different userIds are isolated', () async {
      await db.userPreferencesDao.set('alice', 'k', '"a"');
      await db.userPreferencesDao.set('bob', 'k', '"b"');

      expect(await db.userPreferencesDao.get('alice', 'k'), '"a"');
      expect(await db.userPreferencesDao.get('bob', 'k'), '"b"');
      expect((await db.userPreferencesDao.getAll('alice')).length, 1);
    });
  });
}
