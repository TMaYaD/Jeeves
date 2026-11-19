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
  /// [updatedAt] stamps the row — and the op that describes it — with a given
  /// ISO-8601 timestamp instead of now. A carried copy uses it to keep the
  /// source row's own timestamp: a copy stamped "now" would look newer than a
  /// change it actually predates, and would overwrite that change at the next
  /// sign-in.
  ///
  /// The row is looked up by `(user_id, key)` — the domain key — and then either
  /// UPDATEd in place or INSERTed under the derived entity id. The op names the
  /// derivation either way, which is the entity the peers hold because the
  /// derivation is the *only* id in circulation: this DAO mints it on INSERT,
  /// `initial_upload_plan` derives it when it authors a pre-existing row, and
  /// `DomainProjector` realigns a pulled row onto the op's entity id. The select
  /// / write pair runs inside a transaction so concurrent setters cannot race
  /// past the UNIQUE(user_id, key) constraint.
  Future<void> set(
    String userId,
    String key,
    String? jsonValue, {
    String? updatedAt,
  }) async {
    final timestamp = updatedAt ?? DateTime.now().toUtc().toIso8601String();
    // The KV entity id policy: `uuid5(workspace_id, key)`, so two devices that
    // create the same preference offline converge as one entity under
    // field-grain merge instead of forking. The `value` field is the one
    // the Conflict Strategy registry arbitrates.
    //
    // The workspace is the **User-global preferences one**, not the default GTD
    // Workspace: preferences live behind a boundary that no Service is ever
    // granted, and the derivation is keyed off that Workspace's id.
    //
    // The local row is minted under this id too, so local state and the op log
    // address one row from the start rather than waiting for the projector to
    // realign a random one.
    final entityId = preferenceEntityId(userPreferencesWorkspaceId(userId), key);
    await _db.capturing(() async {
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
            Variable(timestamp),
          ],
          updates: {_db.userPreferences},
        );
      } else {
        await _db.customUpdate(
          'UPDATE user_preferences SET value = ?, updated_at = ? '
          'WHERE user_id = ? AND "key" = ?',
          variables: [
            Variable(jsonValue),
            Variable(timestamp),
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
          'updated_at': timestamp,
        },
      );
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

  /// Every key that has a row for [userId], tombstones included. [getAll] hides
  /// tombstones, so "has this user ever written this key" needs its own read.
  Future<Set<String>> getRowKeys(String userId) async {
    final rows = await _db.customSelect(
      'SELECT "key" FROM user_preferences WHERE user_id = ?',
      variables: [Variable(userId)],
      readsFrom: {_db.userPreferences},
    ).get();
    return {for (final r in rows) r.read<String>('key')};
  }

  /// Upserts only the entries whose key has no row at all (value or tombstone)
  /// for [userId]; the existence check and the writes share one transaction so a
  /// pulled row can never be overwritten by a stale local value.
  Future<void> setAllIfAbsent(String userId, Map<String, String> entries) async {
    if (entries.isEmpty) return;
    await _db.capturing(() async {
      final present = await getRowKeys(userId);
      for (final entry in entries.entries) {
        if (present.contains(entry.key)) continue;
        await set(userId, entry.key, entry.value);
      }
    });
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
    await _db.capturing(() async {
      for (final entry in entries.entries) {
        await set(userId, entry.key, entry.value);
      }
    });
  }

  /// Carries the newest value of each preference key on this device into
  /// [userId]'s copy of it.
  ///
  /// A device holds one preference row per `(user id, key)` pair, and the
  /// current user id changes on sign-in and on sign-out. Without this the app
  /// would swap between two copies of every setting: the one the account
  /// brought and the one the device kept. The carry moves the more recent of
  /// the two into [userId]'s row, in both directions — a setting changed while
  /// signed out reaches the account at sign-in, and a setting changed while
  /// signed in comes back to the device at sign-out.
  ///
  /// The carried row keeps the **source row's** `updated_at`, so a copy cannot
  /// look newer than a change that happened before it and overwrite that
  /// change at the next sign-in.
  ///
  /// Nothing is deleted and no source row is modified: only [userId]'s own row
  /// for the key is written, and only when the source is strictly newer than
  /// it. Two copies carrying the same timestamp are left alone, and a
  /// timestamp that cannot be parsed counts as the oldest.
  ///
  /// **The read, the decision and the write happen under one writer.** The
  /// whole body runs inside a single capturing transaction, so a change that
  /// lands while the carry is in flight — a row the projector writes from a
  /// pull, say — cannot slip between the read and the write and be undone by
  /// a decision taken before it. A capturing scope holds the store's write
  /// lock for its whole life, so such a write waits for the carry to commit
  /// and lands after it; the nested `set` calls are savepoints inside the one
  /// transaction.
  Future<void> carryNewestPreferencesInto(String userId) async {
    await _db.capturing(() async {
      final rows = await _db.customSelect(
        'SELECT user_id, "key", value, updated_at FROM user_preferences',
        readsFrom: {_db.userPreferences},
      ).get();
      if (rows.isEmpty) return;

      // The newest row per key among the rows stored under another user id,
      // and the current user's own row for the same key.
      final newestOther = <String, QueryRow>{};
      final current = <String, QueryRow>{};
      for (final row in rows) {
        final key = row.read<String>('key');
        if (row.read<String>('user_id') == userId) {
          current[key] = row;
          continue;
        }
        final held = newestOther[key];
        if (held == null || _isNewerThan(row, held)) {
          newestOther[key] = row;
        }
      }
      if (newestOther.isEmpty) return;

      final carries = <MapEntry<String, QueryRow>>[];
      for (final entry in newestOther.entries) {
        final mine = current[entry.key];
        if (mine != null && !_isNewerThan(entry.value, mine)) {
          // The current user's copy is newer, or equally new: leave it alone.
          continue;
        }
        carries.add(entry);
      }
      if (carries.isEmpty) return;

      for (final carry in carries) {
        final source = carry.value;
        await set(
          userId,
          carry.key,
          source.read<String?>('value'),
          updatedAt: source.read<String?>('updated_at'),
        );
      }
    });
  }

  /// Whether [candidate] carries a strictly newer timestamp than [other].
  ///
  /// A timestamp that cannot be parsed counts as the oldest, so it never wins
  /// over a readable one and two unreadable ones count as equal.
  static bool _isNewerThan(QueryRow candidate, QueryRow other) {
    final candidateAt = _parseTimestamp(candidate.read<String?>('updated_at'));
    final otherAt = _parseTimestamp(other.read<String?>('updated_at'));
    if (candidateAt == null) return false;
    if (otherAt == null) return true;
    return candidateAt.isAfter(otherAt);
  }

  /// The UTC instant [raw] names, or null when it names none.
  static DateTime? _parseTimestamp(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }
}
