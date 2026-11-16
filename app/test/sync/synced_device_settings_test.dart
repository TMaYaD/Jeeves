/// Evening Shutdown settings, recent searches and the first-launch card
/// dismissal follow the user to a second device (#937). The app's own providers
/// run over each simulated device's store, so what is asserted is what the
/// settings screens would read.
@TestOn('!browser')
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/providers/auth_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/onboarding_provider.dart';
import 'package:jeeves/providers/search_provider.dart';
import 'package:jeeves/providers/shutdown_settings_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';
import 'harness/sim_device.dart';
import 'harness/sim_workspace.dart';

void main() {
  setUpAll(configureSqliteForTests);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    onboardingSeenNotifier.value = false;
  });

  ProviderContainer appOver(SimDevice device) {
    final c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(device.domain),
    ]);
    c.read(currentUserIdProvider.notifier).setUserId(device.userId);
    addTearDown(c.dispose);
    return c;
  }

  test('a change on device A is what device B reports after sync', () async {
    final workspace = await SimWorkspace.create();
    addTearDown(workspace.close);
    final appA = appOver(workspace.a);
    final appB = appOver(workspace.b);
    await appA.read(syncedPreferencesProvider.future);
    await appB.read(syncedPreferencesProvider.future);

    final shutdown = appA.read(shutdownSettingsProvider.notifier);
    await shutdown.setShutdownTime(const TimeOfDay(hour: 21, minute: 45));
    await shutdown.setNotificationEnabled(false);
    await shutdown.setBannerEnabled(false);
    await appA.read(recentSearchesProvider.notifier).add('invoices');
    await appA.read(recentSearchesProvider.notifier).add('taxes');
    await workspace.syncAll();
    await pumpEventQueue();

    final settingsB = appB.read(shutdownSettingsProvider);
    expect(settingsB.shutdownTime, const TimeOfDay(hour: 21, minute: 45));
    expect(settingsB.notificationEnabled, isFalse);
    expect(settingsB.bannerEnabled, isFalse);
    expect(appB.read(recentSearchesProvider), ['taxes', 'invoices']);

    // The dismissal travels as a synced preference.
    await appA.read(syncedPreferencesProvider.notifier).set('onboarding_seen', true);
    await workspace.syncAll();
    await pumpEventQueue();
    expect(
      appB.read(syncedPreferencesProvider).asData!.value.get<bool>('onboarding_seen'),
      isTrue,
    );
  });
}
