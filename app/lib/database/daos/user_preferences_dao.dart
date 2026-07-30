/// DAO for cross-device synced key-value user preferences.
///
/// A row's primary key is the KV collection's derived entity id
/// (`preferenceEntityId(userPreferencesWorkspaceId(userId), key)`), so the local
/// row and the op log address one entity from the moment it is created. The
/// UNIQUE(user_id, key) constraint gives upsert semantics. NULL value is a
/// tombstone — excluded from getAll()/get()/watch() results.
library;

import 'package:drift/drift.dart';

import '../../sync/collection_codecs.dart' show userPreferencesCollection;
import '../../sync/ids.dart'
    show preferenceEntityId, userPreferencesWorkspaceId;
import '../gtd_database.dart';

class UserPreferencesDao {
  const UserPreferencesDao(this._db);

  final GtdDatabase _db;

  /// Upserts [key] → [jsonValue] for [userId].
  ///
  /// The row is looked up by `(user_id, key)` — the domain key — and then either
  /// UPDATEd in place or INSERTed under the derived entity id. The op names the
  /// derivation either way, which is the entity the peers hold because the
  /// derivation is the *only* id in circulation: this DAO mints it on INSERT,
  /// `initial_upload_plan` derives it when it authors a pre-existing row, and
  /// `DomainProjector` realigns a pulled row onto the op's entity id. The select
  /// / write pair runs inside a transaction so concurrent setters cannot race
  /// past the UNIQUE(user_id, key) constraint.
  Future<void> set(String userId, String key, String? jsonValue) async {
    final now = DateTime.now().toUtc().toIso8601String();
    // The KV entity id policy: `uuid5(workspace_id, key)`, so two devices that
    // create the same preference offline converge as one entity under
    // field-grain merge instead of forking. The `value` field is the one
    // ADR-0011's Conflict Strategy registry arbitrates.
    //
    // The workspace is the **User-global preferences one**, not the default GTD
    // Workspace: preferences live behind a boundary that no Service is ever
    // granted, and the derivation is keyed off that Workspace's id.
    //
    // The local row is minted under this id too, so local state and the op log
    // address one row from the start rather than waiting for the projector to
    // realign a random one.
    final entityId = preferenceEntityId(userPreferencesWorkspaceId(userId), key);
    await _db.capturing(() => _db.transaction(() async {
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
            Variable(entityId),
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
      _db.opCapture.write(
        collection: userPreferencesCollection,
        entityId: entityId,
        fields: {
          'user_id': userId,
          'key': key,
          'value': jsonValue,
          'updated_at': now,
        },
      );
    }));
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
    await _db.capturing(() => _db.transaction(() async {
      for (final entry in entries.entries) {
        await set(userId, entry.key, entry.value);
      }
    }));
  }
}
