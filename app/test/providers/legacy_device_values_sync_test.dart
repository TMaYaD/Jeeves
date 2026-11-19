import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/auth_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/onboarding_provider.dart';
import 'package:jeeves/providers/search_provider.dart';
import 'package:jeeves/providers/shutdown_settings_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/services/user_preferences_conflict.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

const _legacy = <String, Object>{
  'shutdown_settings_time_hour': 21,
  'shutdown_settings_time_minute': 15,
  'shutdown_settings_notification_enabled': false,
  'shutdown_settings_banner_enabled': false,
  'jeeves_recent_searches': <String>['zeta', 'alpha', 'mid'],
};

ProviderContainer _container(GtdDatabase db) {
  final c = ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
  addTearDown(c.dispose);
  return c;
}

Future<int> _rowCount(GtdDatabase db, String userId) async => (await db
        .customSelect('SELECT 1 FROM user_preferences WHERE user_id = ?',
            variables: [Variable(userId)])
        .get())
    .length;

void main() {
  setUpAll(configureSqliteForTests);
  setUp(() {
    SharedPreferences.setMockInitialValues({..._legacy, 'onboarding_seen': true});
    onboardingSeenNotifier.value = false;
  });

  test('registry: recent searches are an explicit lww key', () {
    expect(preferenceConflictRegistry['jeeves_recent_searches'],
        ConflictStrategy.lww);
    expect(strategyForKey('jeeves_recent_searches'), ConflictStrategy.lww);
  });

  test('signed out: providers report the device values, nothing is written',
      () async {
    final db = GtdDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final c = _container(db);
    await c.read(syncedPreferencesProvider.future);

    final s = c.read(shutdownSettingsProvider);
    expect(s.shutdownTime, const TimeOfDay(hour: 21, minute: 15));
    expect(s.notificationEnabled, isFalse);
    expect(s.bannerEnabled, isFalse);
    expect(c.read(recentSearchesProvider), ['zeta', 'alpha', 'mid']);
    expect(await _rowCount(db, 'local'), 0);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('shutdown_settings_time_hour'), 21);
    expect(prefs.getStringList('jeeves_recent_searches'), ['zeta', 'alpha', 'mid']);
  });

  test('signed in after a cold start as local: rows land under the account only, once',
      () async {
    final db = GtdDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final c = _container(db);
    await c.read(syncedPreferencesProvider.future); // built under 'local'
    c.read(currentUserIdProvider.notifier).setUserId('acct');
    await c.read(syncedPreferencesProvider.future);

    expect(c.read(shutdownSettingsProvider).shutdownTime,
        const TimeOfDay(hour: 21, minute: 15));
    expect(c.read(recentSearchesProvider), ['zeta', 'alpha', 'mid']);
    expect(await _rowCount(db, 'local'), 0);
    expect(await _rowCount(db, 'acct'), 5);
    expect(await db.userPreferencesDao.get('acct', 'jeeves_recent_searches'),
        jsonEncode(['zeta', 'alpha', 'mid']));

    // A second build copies nothing, and does not clobber a later change.
    await c.read(shutdownSettingsProvider.notifier).setNotificationEnabled(true);
    final c2 = _container(db);
    c2.read(currentUserIdProvider.notifier).setUserId('acct');
    await c2.read(syncedPreferencesProvider.future);
    expect(c2.read(shutdownSettingsProvider).notificationEnabled, isTrue);
    expect(await _rowCount(db, 'acct'), 5);
  });

  test('a key that already has a value or a tombstone is not overwritten',
      () async {
    final db = GtdDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.userPreferencesDao
        .set('acct', 'shutdown_settings_time_hour', jsonEncode(7));
    await db.userPreferencesDao.set('acct', 'jeeves_recent_searches', null);
    final c = _container(db);
    c.read(currentUserIdProvider.notifier).setUserId('acct');
    await c.read(syncedPreferencesProvider.future);

    expect(c.read(shutdownSettingsProvider).shutdownTime.hour, 7);
    expect(c.read(recentSearchesProvider), isEmpty);
  });

  test('a fallback value still reads after an unrelated key changes', () async {
    final db = GtdDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final c = _container(db);
    await c.read(syncedPreferencesProvider.future);
    await c.read(syncedPreferencesProvider.notifier).set('unrelated', 1);
    await pumpEventQueue();
    expect(c.read(shutdownSettingsProvider).shutdownTime.hour, 21);
  });

  group('recent searches', () {
    test('caps at 10, most recent first, remove, clear stays cleared', () async {
      SharedPreferences.setMockInitialValues({
        'jeeves_recent_searches': [for (var i = 0; i < 10; i++) 'q$i'],
      });
      final db = GtdDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = _container(db);
      final n = c.read(recentSearchesProvider.notifier);
      await n.add('new');
      expect(c.read(recentSearchesProvider).length, 10);
      expect(c.read(recentSearchesProvider).first, 'new');
      expect(c.read(recentSearchesProvider), isNot(contains('q9')));
      await n.remove('q0');
      expect(c.read(recentSearchesProvider), isNot(contains('q0')));
      await n.clearAll();
      expect(c.read(recentSearchesProvider), isEmpty);
      await pumpEventQueue();
      expect(c.read(recentSearchesProvider), isEmpty,
          reason: 'the tombstone must stop the device list coming back');
    });

    test('an add before the snapshot loads keeps the stored list', () async {
      final db = GtdDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = _container(db);
      await c.read(recentSearchesProvider.notifier).add('fresh');
      expect(c.read(recentSearchesProvider),
          ['fresh', 'zeta', 'alpha', 'mid']);
    });

    test('overlapping adds on this device do not lose one another', () async {
      SharedPreferences.setMockInitialValues({});
      final db = GtdDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = _container(db);
      final n = c.read(recentSearchesProvider.notifier);
      await Future.wait([n.add('alpha'), n.add('beta')]);
      await pumpEventQueue();
      expect(c.read(recentSearchesProvider), containsAll(['alpha', 'beta']));
      expect(c.read(recentSearchesProvider).length, 2);
    });
  });

  group('first-launch card dismissal', () {
    test('a synced true hides the card and is stored on the device', () async {
      SharedPreferences.setMockInitialValues({});
      final db = GtdDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.userPreferencesDao.set('acct', 'onboarding_seen', 'true');
      final c = _container(db);
      c.read(currentUserIdProvider.notifier).setUserId('acct');
      c.read(onboardingSyncProvider);
      await c.read(syncedPreferencesProvider.future);
      await pumpEventQueue();
      expect(onboardingSeenNotifier.value, isTrue);
      expect((await SharedPreferences.getInstance()).getBool('onboarding_seen'),
          isTrue);
    });

    test('a dismissal on this device is written to synced preferences',
        () async {
      SharedPreferences.setMockInitialValues({});
      final db = GtdDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = _container(db);
      c.read(currentUserIdProvider.notifier).setUserId('acct');
      c.read(onboardingSyncProvider);
      await c.read(syncedPreferencesProvider.future);
      await markOnboardingSeen();
      await pumpEventQueue();
      expect(await db.userPreferencesDao.get('acct', 'onboarding_seen'), 'true');
    });

    test('an already-seen device writes true once the account arrives',
        () async {
      onboardingSeenNotifier.value = true;
      final db = GtdDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = _container(db);
      c.read(onboardingSyncProvider);
      await c.read(syncedPreferencesProvider.future);
      expect(await _rowCount(db, 'local'), 0);
      c.read(currentUserIdProvider.notifier).setUserId('acct');
      await c.read(syncedPreferencesProvider.future);
      await pumpEventQueue();
      expect(await db.userPreferencesDao.get('acct', 'onboarding_seen'), 'true');
    });
  });
}
