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

ProviderContainer _container(GtdDatabase db) => ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    container = _container(db);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  group('ClarifyMode', () {
    test('an absent or unrecognised wire value decodes to the default', () {
      expect(ClarifyMode.fromWireValue(null), ClarifyMode.oneToOne);
      expect(ClarifyMode.fromWireValue(''), ClarifyMode.oneToOne);
      // A value written by a future build this one cannot render must degrade
      // to the quick flow rather than throw.
      expect(ClarifyMode.fromWireValue('someFutureMode'), ClarifyMode.oneToOne);
    });

    test('wire values are pinned independently of the Dart enum names', () {
      expect(ClarifyMode.oneToOne.wireValue, 'oneToOne');
      expect(ClarifyMode.nToM.wireValue, 'nToM');
    });

    test('defaultMode is one-to-one', () {
      expect(ClarifyMode.defaultMode, ClarifyMode.oneToOne);
    });
  });

  group('clarifyModeProvider', () {
    test('defaults to oneToOne when nothing is persisted', () async {
      await container.read(syncedPreferencesProvider.future);
      expect(container.read(clarifyModeProvider), ClarifyMode.oneToOne);
    });

    test('setMode persists the wire value and updates state', () async {
      await container.read(syncedPreferencesProvider.future);
      await container.read(clarifyModeProvider.notifier).setMode(ClarifyMode.nToM);

      expect(container.read(clarifyModeProvider), ClarifyMode.nToM);
      expect(
        container
            .read(syncedPreferencesProvider)
            .asData!
            .value
            .get<String>(kClarifyModePrefKey),
        'nToM',
      );
    });

    test('the choice round-trips through the store into a fresh container',
        () async {
      await container.read(syncedPreferencesProvider.future);
      await container.read(clarifyModeProvider.notifier).setMode(ClarifyMode.nToM);

      // A second container over the same database stands in for another device
      // that received the row via PowerSync.
      final other = _container(db);
      addTearDown(other.dispose);
      await other.read(syncedPreferencesProvider.future);

      expect(other.read(clarifyModeProvider), ClarifyMode.nToM);
    });

    test('switching back to oneToOne round-trips too', () async {
      await container.read(syncedPreferencesProvider.future);
      final notifier = container.read(clarifyModeProvider.notifier);
      await notifier.setMode(ClarifyMode.nToM);
      await notifier.setMode(ClarifyMode.oneToOne);

      expect(container.read(clarifyModeProvider), ClarifyMode.oneToOne);
      expect(
        container
            .read(syncedPreferencesProvider)
            .asData!
            .value
            .get<String>(kClarifyModePrefKey),
        'oneToOne',
      );
    });

    test('a corrupt stored value reads as the default rather than throwing',
        () async {
      await container.read(syncedPreferencesProvider.future);
      // Write a value no build understands, straight past the typed setter.
      await container
          .read(syncedPreferencesProvider.notifier)
          .set(kClarifyModePrefKey, 'not_a_mode');

      expect(container.read(clarifyModeProvider), ClarifyMode.oneToOne);
    });
  });
}
