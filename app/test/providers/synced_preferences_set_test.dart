import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../test_helpers.dart';

ProviderContainer _container() {
  return ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(GtdDatabase(NativeDatabase.memory())),
    ],
  );
}

void main() {
  setUpAll(configureSqliteForTests);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('state after each set', () async {
    final c = _container();
    addTearDown(c.dispose);
    await c.read(syncedPreferencesProvider.future);

    final notifier = c.read(syncedPreferencesProvider.notifier);

    await notifier.set('an_int', 42);
    var snap = c.read(syncedPreferencesProvider).asData!.value;
    expect(snap.get<int>('an_int'), 42, reason: 'after set 1');

    await notifier.set('a_bool', false);
    snap = c.read(syncedPreferencesProvider).asData!.value;
    expect(snap.get<int>('an_int'), 42, reason: 'after set 2 - an_int still there');
    expect(snap.get<bool>('a_bool'), false, reason: 'after set 2 - a_bool added');

    await notifier.set('a_str', 'hello');
    snap = c.read(syncedPreferencesProvider).asData!.value;
    expect(snap.get<int>('an_int'), 42, reason: 'after set 3 - an_int still there');
    expect(snap.get<bool>('a_bool'), false, reason: 'after set 3 - a_bool still there');
    expect(snap.get<String>('a_str'), 'hello', reason: 'after set 3 - a_str added');
  });
}
