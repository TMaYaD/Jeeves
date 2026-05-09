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
  /// SQLite forbids UPSERT (`INSERT ... ON CONFLICT DO UPDATE`) at the parser
  /// level on views, and PowerSync exposes `user_preferences` as a view in
  /// production (only [NativeDatabase] tests see a real table). To stay
  /// compatible with both, the row is looked up first and then either UPDATEd
  /// in place (preserving the existing `id` so PowerSync's CRUD queue stays
  /// clean) or INSERTed with a fresh UUID. The select / write pair runs
  /// inside a transaction so concurrent setters cannot race past the
  /// UNIQUE(user_id, key) constraint.
  Future<void> set(String userId, String key, String? jsonValue) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _db.transaction(() async {
      final existing = await _db.customSelect(
        'SELECT id FROM user_preferences WHERE user_id = ? AND "key" = ?',
        variables: [Variable(userId), Variable(key)],
        readsFrom: {_db.userPreferences},
      ).get();
      if (existing.isEmpty) {
        await _db.customInsert(
          'INSERT INTO user_preferences (id, user_id, "key", value, updated_at) '
          'VALUES (?, ?, ?, ?, ?)',
          variables: [
            Variable(uuid.v4()),
            Variable(userId),
            Variable(key),
            Variable(jsonValue),
            Variable(now),
          ],
          updates: {_db.userPreferences},
        );
      } else {
        await _db.customUpdate(
          'UPDATE user_preferences SET value = ?, updated_at = ? '
          'WHERE user_id = ? AND "key" = ?',
          variables: [
            Variable(jsonValue),
            Variable(now),
            Variable(userId),
            Variable(key),
          ],
          updates: {_db.userPreferences},
        );
      }
    });
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
