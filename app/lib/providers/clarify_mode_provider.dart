/// The synced `clarify_mode` preference — which of the two clarify modes
/// (CONTEXT.md § GTD Core) the clarify surfaces run in.
///
/// Backed by the `user_preferences` synced key-value store, so the choice
/// replicates across the user's devices like every other setting. Conflicts
/// resolve by last-write-wins, registered explicitly in
/// `services/user_preferences_conflict.dart` per ADR-0011.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/clarify_mode.dart';
import 'synced_preferences_provider.dart';

/// The `user_preferences` key holding the persisted [ClarifyMode.wireValue].
const kClarifyModePrefKey = 'clarify_mode';

final clarifyModeProvider = NotifierProvider<ClarifyModeNotifier, ClarifyMode>(
  ClarifyModeNotifier.new,
);

class ClarifyModeNotifier extends Notifier<ClarifyMode> {
  @override
  ClarifyMode build() {
    // Re-derive whenever synced preferences change — including a cross-device
    // PowerSync update arriving after first build.
    ref.listen(syncedPreferencesProvider, (_, next) {
      if (next is AsyncData<SyncedPreferences>) {
        state = _fromPrefs(next.value);
      }
    });
    // Return the default immediately; the listener corrects it once the DB
    // snapshot loads.
    final current = ref.read(syncedPreferencesProvider).asData?.value;
    return current != null ? _fromPrefs(current) : ClarifyMode.defaultMode;
  }

  ClarifyMode _fromPrefs(SyncedPreferences prefs) =>
      ClarifyMode.fromWireValue(prefs.get<String>(kClarifyModePrefKey));

  Future<void> setMode(ClarifyMode mode) async {
    await syncedPrefs(ref).set(kClarifyModePrefKey, mode.wireValue);
    state = mode;
  }
}
