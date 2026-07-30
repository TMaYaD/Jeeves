/// The user's selected [ClarifyMode], replicated across devices via the
/// `user_preferences` synced key-value store (issue #433).
///
/// Reads re-derive from `syncedPreferencesProvider` so a cross-device change
/// lands without a restart; writes go through [SyncedPreferencesNotifier.set]
/// and update state eagerly.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/clarify_mode.dart';
import 'synced_preferences_provider.dart';

final clarifyModeProvider = NotifierProvider<ClarifyModeNotifier, ClarifyMode>(
  ClarifyModeNotifier.new,
);

class ClarifyModeNotifier extends Notifier<ClarifyMode> {
  @override
  ClarifyMode build() {
    // Re-derive whenever synced preferences change, including a pull that
    // reduces another device's write in.
    ref.listen(syncedPreferencesProvider, (_, next) {
      if (next is AsyncData<SyncedPreferences>) {
        state = _fromPrefs(next.value);
      }
    });
    // Return the default immediately; the listener above corrects it once the
    // DB snapshot loads.
    final current = ref.read(syncedPreferencesProvider).asData?.value;
    return current != null ? _fromPrefs(current) : ClarifyMode.oneToOne;
  }

  ClarifyMode _fromPrefs(SyncedPreferences prefs) =>
      ClarifyMode.fromString(prefs.get<String>(kClarifyModePrefKey));

  Future<void> setMode(ClarifyMode mode) async {
    await syncedPrefs(ref).set(kClarifyModePrefKey, mode.name);
    state = mode;
  }
}
