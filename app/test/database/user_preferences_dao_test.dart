import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import '../test_helpers.dart';

const _userId = 'test-user';

/// The user id the device holds while signed out.
const _signedOutUserId = 'local';

/// The account id the device holds while signed in.
const _accountId = 'account-a';

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

  group('UserPreferencesDao.carryNewestPreferencesInto', () {
    late GtdDatabase db;

    setUp(() {
      db = _openDb();
    });
    tearDown(() => db.close());

    test('a snooze floor is never lowered by a carry, even from a newer write',
        () async {
      final dao = db.userPreferencesDao;
      const key = 'planning_notification_snoozed_until';

      await dao.set(_accountId, key, '"2026-01-01T18:00:00.000Z"',
          updatedAt: '2026-01-01T10:00:00.000Z');
      await dao.set(_signedOutUserId, key, '"2026-01-01T17:00:00.000Z"',
          updatedAt: '2026-01-01T11:00:00.000Z');

      await dao.carryNewestPreferencesInto(_accountId);

      expect(await dao.get(_accountId, key), '"2026-01-01T18:00:00.000Z"');
    });

    test('a later snooze value is carried even when its write is older',
        () async {
      final dao = db.userPreferencesDao;
      const key = 'planning_notification_snoozed_until';

      await dao.set(_accountId, key, '"2026-01-01T17:00:00.000Z"',
          updatedAt: '2026-01-01T11:00:00.000Z');
      await dao.set(_signedOutUserId, key, '"2026-01-01T18:00:00.000Z"',
          updatedAt: '2026-01-01T10:00:00.000Z');

      await dao.carryNewestPreferencesInto(_accountId);

      expect(await dao.get(_accountId, key), '"2026-01-01T18:00:00.000Z"');
    });

    test('the latest snooze floor of three users wins, not the newest write',
        () async {
      final dao = db.userPreferencesDao;
      const key = 'planning_notification_snoozed_until';

      await dao.set(_accountId, key, '"2026-01-01T16:00:00.000Z"',
          updatedAt: '2026-01-01T09:00:00.000Z');
      await dao.set(_signedOutUserId, key, '"2026-01-01T18:00:00.000Z"',
          updatedAt: '2026-01-01T10:00:00.000Z');
      await dao.set('other-account', key, '"2026-01-01T17:00:00.000Z"',
          updatedAt: '2026-01-01T11:00:00.000Z');

      await dao.carryNewestPreferencesInto(_accountId);

      expect(await dao.get(_accountId, key), '"2026-01-01T18:00:00.000Z"');
    });

    test('a newer clear of a snooze is carried over an older clear', () async {
      final dao = db.userPreferencesDao;
      const key = 'planning_notification_snoozed_until';

      await dao.set(_accountId, key, null,
          updatedAt: '2026-01-01T10:00:00.000Z');
      await dao.set(_signedOutUserId, key, null,
          updatedAt: '2026-01-01T12:00:00.000Z');

      await dao.carryNewestPreferencesInto(_accountId);

      final row = (await db.customSelect(
        'SELECT updated_at FROM user_preferences WHERE user_id = ? AND "key" = ?',
        variables: [Variable.withString(_accountId), Variable.withString(key)],
      ).getSingle());
      expect(DateTime.parse(row.read<String>('updated_at')).toUtc(),
          DateTime.utc(2026, 1, 1, 12));
    });

    test('a clear that was carried over stays in force on a later carry',
        () async {
      final dao = db.userPreferencesDao;
      const key = 'planning_notification_snoozed_until';

      // The account cleared at 10:00; one copy holds an 18:00 floor written at
      // 09:00 (before the clear), another a 12:00 floor written at 11:00.
      await dao.set(_accountId, key, null,
          updatedAt: '2026-01-01T10:00:00.000Z');
      await dao.set(_signedOutUserId, key, '"2026-01-01T18:00:00.000Z"',
          updatedAt: '2026-01-01T09:00:00.000Z');
      await dao.set('other-account', key, '"2026-01-01T12:00:00.000Z"',
          updatedAt: '2026-01-01T11:00:00.000Z');

      await dao.carryNewestPreferencesInto(_accountId);
      expect(await dao.get(_accountId, key), '"2026-01-01T12:00:00.000Z"');

      // The second carry must not revive the floor the clear silenced.
      await dao.carryNewestPreferencesInto(_accountId);
      expect(await dao.get(_accountId, key), '"2026-01-01T12:00:00.000Z"');
    });

    test('a change that lands while a setting is carried in is not undone',
        () async {
      final dao = db.userPreferencesDao;

      // The account's own copy of a setting, and the copy the device kept
      // while it was signed out. The device's is the newer one, so the carry
      // would move it into the account's row.
      await dao.set(_accountId, 'k', '"account"',
          updatedAt: '2026-01-01T00:00:00.000Z');
      await dao.set(_signedOutUserId, 'k', '"device"',
          updatedAt: '2026-01-02T00:00:00.000Z');

      // A change pulled from another device, landing while the carry runs.
      // The carry must not undo it: a decision taken from a read taken before
      // it landed is a decision about a state that no longer exists.
      final carry = dao.carryNewestPreferencesInto(_accountId);
      final pulled = dao.set(_accountId, 'k', '"pulled"',
          updatedAt: '2026-01-03T00:00:00.000Z');
      await Future.wait([carry, pulled]);

      expect(await dao.get(_accountId, 'k'), '"pulled"');
      // The source row is never touched.
      expect(await dao.get(_signedOutUserId, 'k'), '"device"');
    });
  });
}
