import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/clarify_mode.dart';
import 'package:jeeves/providers/clarify_mode_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

// Must match currentUserIdProvider.build() default so the notifier finds rows.
const _userId = 'local';

/// A memory database closed when the running test ends.
GtdDatabase _memoryDb() {
  final db = GtdDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

ProviderContainer _container(GtdDatabase db) => ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );

/// A container over its own fresh database, both disposed when the test ends.
ProviderContainer _containerWithFreshDb() {
  final container = _container(_memoryDb());
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUpAll(configureSqliteForTests);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('ClarifyMode.fromString', () {
    test('round-trips both modes by name', () {
      for (final mode in ClarifyMode.values) {
        expect(ClarifyMode.fromString(mode.name), mode);
      }
    });

    test('falls back to oneToOne for absent or unrecognised values', () {
      expect(ClarifyMode.fromString(null), ClarifyMode.oneToOne);
      expect(ClarifyMode.fromString(''), ClarifyMode.oneToOne);
      // A value a future client might write must degrade to the shipped mode
      // rather than wedge the Inbox in a mode this build cannot drive.
      expect(ClarifyMode.fromString('someFutureMode'), ClarifyMode.oneToOne);
    });

    test('wire values are the names the preference is stored under', () {
      expect(ClarifyMode.oneToOne.name, 'oneToOne');
      expect(ClarifyMode.nToM.name, 'nToM');
    });
  });

  group('clarifyModeProvider', () {
    test('defaults to oneToOne when nothing is persisted', () async {
      final container = _containerWithFreshDb();

      expect(container.read(clarifyModeProvider), ClarifyMode.oneToOne);

      await container.read(syncedPreferencesProvider.future);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(clarifyModeProvider), ClarifyMode.oneToOne,
          reason: 'an empty prefs snapshot must not move the mode');
    });

    test('setMode updates state and persists under the wire key', () async {
      final container = _containerWithFreshDb();
      await container.read(syncedPreferencesProvider.future);

      await container.read(clarifyModeProvider.notifier).setMode(
            ClarifyMode.nToM,
          );

      expect(container.read(clarifyModeProvider), ClarifyMode.nToM);
      // Pin the wire key and encoding, not just the model.
      expect(
        container
            .read(syncedPreferencesProvider)
            .asData!
            .value
            .get<String>('clarify_mode'),
        'nToM',
      );
      expect(
        await container.read(databaseProvider).userPreferencesDao.get(
              _userId,
              'clarify_mode',
            ),
        '"nToM"',
      );
    });

    test('toggling back to oneToOne round-trips', () async {
      final container = _containerWithFreshDb();
      await container.read(syncedPreferencesProvider.future);
      final notifier = container.read(clarifyModeProvider.notifier);

      await notifier.setMode(ClarifyMode.nToM);
      await notifier.setMode(ClarifyMode.oneToOne);

      expect(container.read(clarifyModeProvider), ClarifyMode.oneToOne);
    });

    test('the mode survives a provider-container recreation', () async {
      final db = _memoryDb();

      final first = _container(db);
      await first.read(syncedPreferencesProvider.future);
      await first.read(clarifyModeProvider.notifier).setMode(ClarifyMode.nToM);
      first.dispose();

      final second = _container(db);
      addTearDown(second.dispose);
      await second.read(syncedPreferencesProvider.future);
      // Flush the syncedPreferences listener inside the notifier.
      await Future<void>.delayed(Duration.zero);

      expect(second.read(clarifyModeProvider), ClarifyMode.nToM);
    });

    test('an unrecognised persisted value reads as oneToOne', () async {
      final container = _containerWithFreshDb();
      await container.read(syncedPreferencesProvider.future);
      await container
          .read(syncedPreferencesProvider.notifier)
          .set('clarify_mode', 'someFutureMode');
      await Future<void>.delayed(Duration.zero);

      expect(container.read(clarifyModeProvider), ClarifyMode.oneToOne);
    });
  });
}
