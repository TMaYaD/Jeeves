/// Riverpod provider for cross-device synced user preferences backed by the
/// `user_preferences` Drift table (replicated via PowerSync).
///
/// All preferences are stored as JSON-encoded TEXT. Reads decode on the fly;
/// writes JSON-encode before persisting. A NULL value is a tombstone — treated
/// as absent by get/watch.
///
/// Usage:
///   // Read
///   final v = ref.read(syncedPreferencesProvider).asData?.value.get('my_key') as int?;
///   // Write
///   await ref.read(syncedPreferencesProvider.notifier).set('my_key', 42);
///   // Remove (tombstone)
///   await ref.read(syncedPreferencesProvider.notifier).remove('my_key');
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/daos/user_preferences_dao.dart';
import 'auth_provider.dart';
import 'database_provider.dart';

// ---------------------------------------------------------------------------
// Keys scheduled for migration from SharedPreferences on first run after
// upgrade. Ceremony keys (banner dismissed, notification skip/snooze,
// ritual completed) are copied to Drift but NOT cleared from SharedPreferences
// so the startup init functions (called before runApp) continue to work.
// Settings keys are fully moved — cleared from SharedPreferences after copy.
// ---------------------------------------------------------------------------

const _settingsKeys = <String>[
  'focus_settings_sprint_duration_minutes',
  'focus_settings_break_duration_minutes',
  'focus_session_planning_settings_time_hour',
  'focus_session_planning_settings_time_minute',
  'focus_session_planning_settings_notification_enabled',
  'focus_session_planning_settings_banner_enabled',
  'focus_session_planning_settings_default_snooze_duration',
];

const _ceremonyKeys = <String>[
  'planning_banner_dismissed_date',
  'planning_notification_skipped_date',
  'planning_notification_snoozed_until',
  'shutdown_ritual_completed_date',
  'shutdown_banner_dismissed_date',
  'shutdown_notification_skipped_date',
  'shutdown_notification_snoozed_until',
];

// ---------------------------------------------------------------------------
// SyncedPreferences value class
// ---------------------------------------------------------------------------

/// Immutable snapshot of the decoded preference map.
class SyncedPreferences {
  const SyncedPreferences(this._map);

  final Map<String, dynamic> _map;

  T? get<T>(String key) {
    final v = _map[key];
    if (v is T) return v;
    return null;
  }

  bool containsKey(String key) => _map.containsKey(key);

  Iterable<MapEntry<String, dynamic>> get entries => _map.entries;

  SyncedPreferences copyWith(String key, dynamic value) {
    if (value == null) {
      final m = Map<String, dynamic>.from(_map)..remove(key);
      return SyncedPreferences(m);
    }
    return SyncedPreferences({..._map, key: value});
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

final syncedPreferencesProvider =
    AsyncNotifierProvider<SyncedPreferencesNotifier, SyncedPreferences>(
  SyncedPreferencesNotifier.new,
);

class SyncedPreferencesNotifier
    extends AsyncNotifier<SyncedPreferences> {
  @override
  Future<SyncedPreferences> build() async {
    final db = ref.watch(databaseProvider);
    final userId = ref.watch(currentUserIdProvider);
    final dao = db.userPreferencesDao;

    // One-time migration from SharedPreferences (runs lazily after DB is ready).
    await _migrateSharedPreferencesIfNeeded(dao, userId);
    if (!ref.mounted) return const SyncedPreferences({});

    // Load initial snapshot.
    final initial = await dao.getAll(userId);
    if (!ref.mounted) return const SyncedPreferences({});
    final decoded = _decode(initial);

    // Subscribe to future changes (including cross-device PowerSync updates).
    final sub = dao.watchAll(userId).listen((rows) {
      if (!ref.mounted) return;
      final tombstonedKeys = {
        for (final r in rows.where((r) => r.value == null)) r.key
      };
      final liveMap = _decode({
        for (final r in rows.where((r) => r.value != null)) r.key: r.value!,
      });
      // Merge: preserve in-memory keys that aren't tombstoned in this snapshot
      // and aren't in liveMap — these are optimistic writes not yet in the DB
      // snapshot (can happen when the stream fires between rapid sequential
      // writes). Cross-device tombstones and live data always win.
      final current = state.asData?.value;
      if (current != null) {
        final merged = <String, dynamic>{
          for (final e in current.entries)
            if (!tombstonedKeys.contains(e.key) && !liveMap.containsKey(e.key))
              e.key: e.value,
          ...liveMap,
        };
        state = AsyncData(SyncedPreferences(merged));
      } else {
        state = AsyncData(SyncedPreferences(liveMap));
      }
    });
    ref.onDispose(sub.cancel);

    return SyncedPreferences(decoded);
  }

  // ---------------------------------------------------------------------------
  // Public surface
  // ---------------------------------------------------------------------------

  /// JSON-encodes [value] and upserts under [key] for the current user.
  ///
  /// Persists to the database first, then eagerly updates in-memory state so
  /// callers see consistent reads in the same frame without waiting for the
  /// watchAll stream to re-emit.
  Future<void> set(String key, dynamic value) async {
    final userId = ref.read(currentUserIdProvider);
    final jsonValue = jsonEncode(value);
    await ref.read(databaseProvider).userPreferencesDao.set(userId, key, jsonValue);
    if (!ref.mounted) return;
    // Eager local update — apply to in-memory state immediately after persistence
    // instead of waiting for the watchAll stream to re-emit.
    state = AsyncData(state.asData?.value.copyWith(key, value) ??
        SyncedPreferences({key: value}));
  }

  /// Atomically upserts multiple keys in one DB transaction. Use for cases
  /// where partial persistence would leave the user in an inconsistent state
  /// (e.g. completing a ceremony where both the timestamp and the captured
  /// outputs must persist together).
  ///
  /// On failure (any single write throws inside the transaction) nothing
  /// commits and in-memory state is left untouched.
  Future<void> setMany(Map<String, dynamic> entries) async {
    if (entries.isEmpty) return;
    final userId = ref.read(currentUserIdProvider);
    final encoded = <String, String?>{
      for (final e in entries.entries)
        e.key: e.value == null ? null : jsonEncode(e.value),
    };
    await ref.read(databaseProvider).userPreferencesDao.setAll(userId, encoded);
    if (!ref.mounted) return;
    var next = state.asData?.value ?? const SyncedPreferences({});
    for (final e in entries.entries) {
      next = next.copyWith(e.key, e.value);
    }
    state = AsyncData(next);
  }

  /// Sets [key] to null (tombstone). Subsequent get/watch return null.
  Future<void> remove(String key) async {
    final userId = ref.read(currentUserIdProvider);
    await ref.read(databaseProvider).userPreferencesDao.set(userId, key, null);
    if (!ref.mounted) return;
    state = AsyncData(state.asData?.value.copyWith(key, null) ??
        const SyncedPreferences({}));
  }

  // ---------------------------------------------------------------------------
  // SharedPreferences → Drift one-shot migration
  // ---------------------------------------------------------------------------

  Future<void> _migrateSharedPreferencesIfNeeded(
    UserPreferencesDao dao,
    String userId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    const migratedKey = '_legacy_synced_preferences_migrated_v1';
    if (prefs.getBool(migratedKey) == true) return;

    final entries = <String, String?>{};

    // Settings keys: int / bool / String
    for (final key in _settingsKeys) {
      final raw = prefs.get(key);
      if (raw == null) continue;
      entries[key] = _encodeRaw(raw);
    }

    // Ceremony keys: all stored as String (ISO-8601 date or datetime)
    for (final key in _ceremonyKeys) {
      final raw = prefs.get(key);
      if (raw == null) continue;
      entries[key] = _encodeRaw(raw);
    }

    if (entries.isNotEmpty) {
      await dao.setAll(userId, entries);
    }

    // Clear only settings keys from SharedPreferences (ceremony keys remain
    // so the startup init functions can still read them on cold start).
    for (final key in _settingsKeys) {
      if (entries.containsKey(key)) await prefs.remove(key);
    }

    await prefs.setBool(migratedKey, true);
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Map<String, dynamic> _decode(Map<String, String> raw) {
    final result = <String, dynamic>{};
    for (final entry in raw.entries) {
      try {
        result[entry.key] = jsonDecode(entry.value);
      } catch (_) {
        assert(() {
          debugPrint(
              'SyncedPreferences: failed to decode key "${entry.key}", using raw value');
          return true;
        }());
        result[entry.key] = entry.value;
      }
    }
    return result;
  }

  String _encodeRaw(Object raw) {
    if (raw is int) return jsonEncode(raw);
    if (raw is bool) return jsonEncode(raw);
    if (raw is String) return jsonEncode(raw);
    if (raw is double) return jsonEncode(raw);
    return jsonEncode(raw.toString());
  }
}

/// Convenience accessor — reads the notifier without requiring a Ref extension.
SyncedPreferencesNotifier syncedPrefs(Ref ref) =>
    ref.read(syncedPreferencesProvider.notifier);
