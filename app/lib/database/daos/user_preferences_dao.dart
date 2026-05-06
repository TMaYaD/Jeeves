/// DAO for cross-device synced key-value user preferences.
///
/// Each preference row has a client-generated UUID primary key and a
/// UNIQUE(user_id, key) constraint for upsert semantics. NULL value is a
/// tombstone — excluded from getAll()/get()/watch() results.
library;

import 'package:drift/drift.dart';
import 'package:powersync/powersync.dart' show uuid;

import '../gtd_database.dart';

class UserPreferencesDao {
  const UserPreferencesDao(this._db);

  final GtdDatabase _db;

  /// Upserts [key] → [jsonValue] for [userId].
  ///
  /// Generates a new UUID for `id` on insert; on conflict for (user_id, key),
  /// updates value and updated_at in-place (preserving the existing id so
  /// PowerSync's CRUD queue stays clean).
  Future<void> set(String userId, String key, String? jsonValue) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final id = uuid.v4();
    await _db.customStatement(
      '''
      INSERT INTO user_preferences (id, user_id, "key", value, updated_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT (user_id, "key") DO UPDATE SET
        value      = excluded.value,
        updated_at = excluded.updated_at
      ''',
      [id, userId, key, jsonValue, now],
    );
    _db.markTablesUpdated({_db.userPreferences});
  }

  /// Returns the raw JSON-encoded value for [key] and [userId], or null if
  /// the row is absent or tombstoned (value IS NULL).
  Future<String?> get(String userId, String key) async {
    final rows = await _db.customSelect(
      'SELECT value FROM user_preferences WHERE user_id = ? AND "key" = ? AND value IS NOT NULL',
      variables: [Variable(userId), Variable(key)],
      readsFrom: {_db.userPreferences},
    ).get();
    if (rows.isEmpty) return null;
    return rows.first.read<String?>('value');
  }

  /// Stream that re-emits the raw JSON-encoded value for [key] and [userId]
  /// whenever it changes. Emits null when the row is absent or tombstoned.
  Stream<String?> watch(String userId, String key) {
    return _db.customSelect(
      'SELECT value FROM user_preferences WHERE user_id = ? AND "key" = ? AND value IS NOT NULL',
      variables: [Variable(userId), Variable(key)],
      readsFrom: {_db.userPreferences},
    ).watchSingleOrNull().map((row) => row?.read<String?>('value'));
  }

  /// Returns all non-tombstoned rows as a {key → json_value} map.
  Future<Map<String, String>> getAll(String userId) async {
    final rows = await _db.customSelect(
      'SELECT "key", value FROM user_preferences WHERE user_id = ? AND value IS NOT NULL',
      variables: [Variable(userId)],
      readsFrom: {_db.userPreferences},
    ).get();
    return {for (final r in rows) r.read<String>('key'): r.read<String>('value')};
  }

  /// Stream of ALL rows (including tombstones) for [userId]. Used by
  /// SyncedPreferencesNotifier to detect deletions and rebuild its map.
  Stream<List<UserPreference>> watchAll(String userId) {
    return (_db.select(_db.userPreferences)
          ..where((r) => r.userId.equals(userId)))
        .watch();
  }

  /// Upserts multiple entries in a single transaction.
  Future<void> setAll(String userId, Map<String, String?> entries) async {
    if (entries.isEmpty) return;
    await _db.transaction(() async {
      for (final entry in entries.entries) {
        await set(userId, entry.key, entry.value);
      }
    });
  }
}
