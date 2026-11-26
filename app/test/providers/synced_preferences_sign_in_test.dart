import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/focus_settings.dart';
import 'package:jeeves/providers/auth_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_settings_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../test_helpers.dart';

/// The user id the device holds while signed out.
const _signedOutUserId = 'local';

/// The account id the device holds while signed in.
const _accountId = 'account-a';

const _sprintDurationKey = kFocusSprintDurationMinutesPrefKey;

/// A setting the focus settings do not read, used to watch a row survive a
/// switch.
const _otherKey = 'some_other_setting';

ProviderContainer _container(GtdDatabase db) {
  return ProviderContainer(
    overrides: [databaseProvider.overrideWithValue(db)],
  );
}

/// Signs [userId] in — or signs out when [userId] is null — and returns the
/// settings the app shows afterwards.
///
/// `build()` watches the current user id, so the provider rebuilds by itself.
/// The rebuild reads the new user's rows, so the test waits for a fresh
/// snapshot that shows what those rows hold. A snapshot left over from before
/// the switch shows the *other* user's settings, and the two agree only by
/// accident, so the wait also insists on a snapshot the provider has not
/// published before the switch.
Future<SyncedPreferences> _switchUser(
  ProviderContainer container, {
  String? userId,
}) async {
  final before = container.read(syncedPreferencesProvider).asData?.value;

  final notifier = container.read(currentUserIdProvider.notifier);
  if (userId == null) {
    notifier.reset();
  } else {
    notifier.setUserId(userId);
  }
  final currentUserId = container.read(currentUserIdProvider);
  expect(currentUserId, userId ?? _signedOutUserId);

  SyncedPreferences? shown;
  await _waitUntil(
    () async {
      final snapshot = container.read(syncedPreferencesProvider).asData?.value;
      if (snapshot == null) return false;
      if (before != null && identical(snapshot, before)) return false;
      final shows = await _showsRows(container, currentUserId, snapshot);
      if (!shows) return false;
      shown = snapshot;
      return true;
    },
    'the preferences provider to show the settings of "$currentUserId"',
  );
  return shown!;
}

/// Whether [snapshot] shows exactly what [userId]'s rows hold.
Future<bool> _showsRows(
  ProviderContainer container,
  String userId,
  SyncedPreferences snapshot,
) async {
  final rows =
      await container.read(databaseProvider).userPreferencesDao.getAll(userId);
  if (rows.length != snapshot.entries.length) return false;
  for (final row in rows.entries) {
    if (snapshot.get(row.key) != jsonDecode(row.value)) return false;
  }
  return true;
}

/// Waits for [condition] to hold, or fails the test saying what it waited for.
Future<void> _waitUntil(
  Future<bool> Function() condition,
  String what,
) async {
  const timeout = Duration(seconds: 5);
  const step = Duration(milliseconds: 5);
  var waited = Duration.zero;
  while (true) {
    if (await condition()) return;
    if (waited >= timeout) {
      fail('Timed out after ${timeout.inSeconds}s waiting for $what.');
    }
    await Future<void>.delayed(step);
    waited += step;
  }
}

/// Every `user_preferences` row on the device, keyed by `user_id/key`.
Future<Map<String, Map<String, String?>>> _preferenceRows(
  ProviderContainer container,
) async {
  final db = container.read(databaseProvider);
  final rows = await db.customSelect(
    'SELECT user_id, "key", value, updated_at FROM user_preferences',
  ).get();
  return {
    for (final row in rows)
      '${row.read<String>('user_id')}/${row.read<String>('key')}': {
        'value': row.read<String?>('value'),
        'updated_at': row.read<String?>('updated_at'),
      },
  };
}

void main() {
  setUpAll(configureSqliteForTests);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('SyncedPreferences across a user-id change', () {
    test('a setting changed while signed out is still there after signing in',
        () async {
      final db = GtdDatabase(NativeDatabase.memory());
      final container = _container(db);
      addTearDown(container.dispose);
      addTearDown(db.close);

      await container.read(syncedPreferencesProvider.future);
      await container
          .read(focusSettingsProvider.notifier)
          .setSprintDurationMinutes(50);
      expect(container.read(focusSettingsProvider).sprintDurationMinutes, 50);

      final prefs = await _switchUser(container, userId: _accountId);

      expect(prefs.get<int>(_sprintDurationKey), 50);
      expect(container.read(focusSettingsProvider).sprintDurationMinutes, 50);
    });

    test('a setting changed while signed in is still there after signing out',
        () async {
      final db = GtdDatabase(NativeDatabase.memory());
      final container = _container(db);
      addTearDown(container.dispose);
      addTearDown(db.close);

      await container.read(syncedPreferencesProvider.future);
      await _switchUser(container, userId: _accountId);
      await container
          .read(focusSettingsProvider.notifier)
          .setSprintDurationMinutes(30);

      final prefs = await _switchUser(container);

      expect(prefs.get<int>(_sprintDurationKey), 30);
      expect(container.read(focusSettingsProvider).sprintDurationMinutes, 30);
    });

    test(
        'a setting changed while signed out is still there after signing in again',
        () async {
      final db = GtdDatabase(NativeDatabase.memory());
      final container = _container(db);
      addTearDown(container.dispose);
      addTearDown(db.close);

      await container.read(syncedPreferencesProvider.future);
      await _switchUser(container, userId: _accountId);
      await _switchUser(container);
      await container
          .read(focusSettingsProvider.notifier)
          .setSprintDurationMinutes(40);

      final prefs = await _switchUser(container, userId: _accountId);

      expect(prefs.get<int>(_sprintDurationKey), 40);
      expect(container.read(focusSettingsProvider).sprintDurationMinutes, 40);
    });

    test('signing out and back in without a change rewrites no row', () async {
      final db = GtdDatabase(NativeDatabase.memory());
      final container = _container(db);
      addTearDown(container.dispose);
      addTearDown(db.close);

      await container.read(syncedPreferencesProvider.future);
      await _switchUser(container, userId: _accountId);
      await container
          .read(focusSettingsProvider.notifier)
          .setSprintDurationMinutes(30);

      final before = await _preferenceRows(container);
      await _switchUser(container);
      await _switchUser(container, userId: _accountId);
      final after = await _preferenceRows(container);

      // The account's own row is untouched: the same value, stamped the same.
      expect(after['$_accountId/$_sprintDurationKey'],
          before['$_accountId/$_sprintDurationKey']);
      expect(container.read(focusSettingsProvider).sprintDurationMinutes, 30);
    });

    test('a setting removed while signed out reads as absent after signing in',
        () async {
      final db = GtdDatabase(NativeDatabase.memory());
      final container = _container(db);
      addTearDown(container.dispose);
      addTearDown(db.close);

      await container.read(syncedPreferencesProvider.future);
      await _switchUser(container, userId: _accountId);
      await container
          .read(focusSettingsProvider.notifier)
          .setSprintDurationMinutes(50);
      await _switchUser(container);
      await container
          .read(syncedPreferencesProvider.notifier)
          .remove(_sprintDurationKey);

      final prefs = await _switchUser(container, userId: _accountId);

      expect(prefs.containsKey(_sprintDurationKey), isFalse);
      expect(prefs.get<int>(_sprintDurationKey), isNull);
    });

    test('every row that existed before a switch still exists after it',
        () async {
      final db = GtdDatabase(NativeDatabase.memory());
      final container = _container(db);
      addTearDown(container.dispose);
      addTearDown(db.close);

      await container.read(syncedPreferencesProvider.future);
      await container.read(syncedPreferencesProvider.notifier).set(_otherKey, 'dark');

      var before = await _preferenceRows(container);
      await _switchUser(container, userId: _accountId);
      var after = await _preferenceRows(container);
      expect(after.keys.toSet(), containsAll(before.keys.toSet()));

      before = after;
      await _switchUser(container);
      after = await _preferenceRows(container);
      expect(after.keys.toSet(), containsAll(before.keys.toSet()));
    });
  });
}
