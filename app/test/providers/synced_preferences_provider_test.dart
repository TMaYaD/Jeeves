import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../test_helpers.dart';

// Must match currentUserIdProvider.build() default so the notifier finds rows.
const _userId = 'local';

ProviderContainer _container({GtdDatabase? db}) {
  final database = db ?? GtdDatabase(NativeDatabase.memory());
  return ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(database),
    ],
  );
}

void main() {
  setUpAll(configureSqliteForTests);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('SyncedPreferencesNotifier', () {
    test('starts loading then resolves to empty map', () async {
      final c = _container();
      addTearDown(c.dispose);

      final result = await c.read(syncedPreferencesProvider.future);
      expect(result.get<String>('anything'), isNull);
    });

    test('set writes to DB and updates in-memory state', () async {
      final c = _container();
      addTearDown(c.dispose);

      await c.read(syncedPreferencesProvider.future);
      await c.read(syncedPreferencesProvider.notifier).set('sprint', 25);

      final prefs = c.read(syncedPreferencesProvider).asData!.value;
      expect(prefs.get<int>('sprint'), 25);

      // Also persisted in DB.
      final db = c.read(databaseProvider);
      expect(await db.userPreferencesDao.get(_userId, 'sprint'), '25');
    });

    test('set stores decoded value in-memory (read-after-write consistent)', () async {
      final c = _container();
      addTearDown(c.dispose);

      await c.read(syncedPreferencesProvider.future);
      await c.read(syncedPreferencesProvider.notifier).set('flag', true);

      // get<bool> must return bool, not a JSON string.
      expect(c.read(syncedPreferencesProvider).asData!.value.get<bool>('flag'), isTrue);
    });

    test('remove tombstones the key', () async {
      final c = _container();
      addTearDown(c.dispose);

      await c.read(syncedPreferencesProvider.future);
      await c.read(syncedPreferencesProvider.notifier).set('k', 'value');
      await c.read(syncedPreferencesProvider.notifier).remove('k');

      expect(c.read(syncedPreferencesProvider).asData!.value.get<String>('k'), isNull);

      // DB row exists but value is null (tombstone).
      final db = c.read(databaseProvider);
      expect(await db.userPreferencesDao.get(_userId, 'k'), isNull);
      final tombstoneRows = await db.customSelect(
        'SELECT "key", value FROM user_preferences WHERE user_id = ? AND "key" = ?',
        variables: [Variable(_userId), Variable('k')],
      ).get();
      expect(tombstoneRows, isNotEmpty);
      expect(tombstoneRows.first.read<String?>('value'), isNull);
    });

    test('JSON round-trip: int, bool, String survive encode/decode', () async {
      final c = _container();
      addTearDown(c.dispose);

      await c.read(syncedPreferencesProvider.future);
      final notifier = c.read(syncedPreferencesProvider.notifier);
      await notifier.set('an_int', 42);
      await notifier.set('a_bool', false);
      await notifier.set('a_str', 'hello world');
      await notifier.set('a_date', '2026-05-06');

      final snapshot = c.read(syncedPreferencesProvider).asData!.value;
      expect(snapshot.get<int>('an_int'), 42);
      expect(snapshot.get<bool>('a_bool'), isFalse);
      expect(snapshot.get<String>('a_str'), 'hello world');
      expect(snapshot.get<String>('a_date'), '2026-05-06');
    });
  });

  group('SyncedPreferencesNotifier — SharedPreferences migration', () {
    test('copies settings keys from SharedPreferences on first build', () async {
      SharedPreferences.setMockInitialValues({
        'focus_settings_sprint_duration_minutes': 30,
        'focus_settings_break_duration_minutes': 5,
      });

      final db = GtdDatabase(NativeDatabase.memory());
      final c = _container(db: db);
      addTearDown(c.dispose);
      addTearDown(db.close);

      final result = await c.read(syncedPreferencesProvider.future);
      expect(result.get<int>('focus_settings_sprint_duration_minutes'), 30);
      expect(result.get<int>('focus_settings_break_duration_minutes'), 5);

      // Settings key cleared from SharedPreferences.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('focus_settings_sprint_duration_minutes'), isFalse);
    });

    test('ceremony keys are copied to Drift but NOT cleared from SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({
        'planning_banner_dismissed_date': '2026-05-06',
      });

      final db = GtdDatabase(NativeDatabase.memory());
      final c = _container(db: db);
      addTearDown(c.dispose);
      addTearDown(db.close);

      await c.read(syncedPreferencesProvider.future);

      // Value is in Drift.
      final raw = await db.userPreferencesDao.get(_userId, 'planning_banner_dismissed_date');
      expect(raw, isNotNull);

      // Still in SharedPreferences (startup init reads it).
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('planning_banner_dismissed_date'), '2026-05-06');
    });

    test('short-circuits when migration sentinel is set', () async {
      final db = GtdDatabase(NativeDatabase.memory());

      SharedPreferences.setMockInitialValues({
        '_legacy_synced_preferences_migrated_v1': true,
        'focus_settings_sprint_duration_minutes': 99,
      });

      final c = _container(db: db);
      addTearDown(c.dispose);
      addTearDown(db.close);

      await c.read(syncedPreferencesProvider.future);

      // Migration was skipped; SharedPreferences value was NOT imported.
      final all = await db.userPreferencesDao.getAll(_userId);
      expect(all.containsKey('focus_settings_sprint_duration_minutes'), isFalse);

      // SharedPreferences key was not touched.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('focus_settings_sprint_duration_minutes'), 99);
    });
  });
}
