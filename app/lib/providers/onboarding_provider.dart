/// State management for the first-launch onboarding card (Issue #250).
///
/// Dismissal is permanent (not date-keyed) because onboarding is a one-time
/// event, unlike the daily planning banner.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_provider.dart';
import 'database_provider.dart';
import 'synced_preferences_provider.dart';

const _kOnboardingSeenKey = 'onboarding_seen';

/// True once the user has permanently dismissed the first-launch onboarding card.
final onboardingSeenNotifier = ValueNotifier<bool>(false);

/// Initialises [onboardingSeenNotifier] from [SharedPreferences].
///
/// Must be called once in [main] after [WidgetsFlutterBinding.ensureInitialized].
Future<void> initOnboardingCompletion() async {
  final prefs = await SharedPreferences.getInstance();
  onboardingSeenNotifier.value = prefs.getBool(_kOnboardingSeenKey) ?? false;
}

/// Permanently marks the onboarding card as seen.
///
/// Updates [onboardingSeenNotifier] synchronously (instant UI collapse) then
/// persists to [SharedPreferences].
Future<void> markOnboardingSeen() async {
  if (onboardingSeenNotifier.value) return;
  onboardingSeenNotifier.value = true;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_kOnboardingSeenKey, true);
}

/// Keeps the on-device dismissal (the cold-start read) and the synced one in
/// step, only ever towards `true`, so last-write-wins can never lose anything.
///
/// Watch it once from the app root. A synced `true` hides the card on this
/// device; a dismissal made here is written to synced preferences once the user
/// is signed in (the signed-out placeholder user has nothing to sync to, and the
/// write happens when the account id arrives).
final onboardingSyncProvider = Provider<void>((ref) {
  var writing = false;

  void reconcile() {
    final synced = ref.read(syncedPreferencesProvider).asData?.value;
    if (synced == null) return;
    final syncedSeen = synced.get<bool>(_kOnboardingSeenKey) == true;
    if (syncedSeen && !onboardingSeenNotifier.value) {
      markOnboardingSeen();
    } else if (!syncedSeen &&
        onboardingSeenNotifier.value &&
        !writing &&
        ref.read(currentUserIdProvider) != 'local') {
      writing = true;
      syncedPrefs(ref)
          .set(_kOnboardingSeenKey, true)
          .whenComplete(() => writing = false);
    }
  }

  ref.listen(syncedPreferencesProvider, (_, __) => reconcile());
  ref.listen(currentUserIdProvider, (_, __) => reconcile());
  onboardingSeenNotifier.addListener(reconcile);
  ref.onDispose(() => onboardingSeenNotifier.removeListener(reconcile));
  reconcile();
});

/// True once the user's database holds at least one item of any kind — a
/// Capture (Inbox or already clarified) or an Outcome.
///
/// Both tables must be watched since the Capture/Outcome split (ADR-0006): a
/// brand-new user's first quick-add is a Capture, a Nirvana import can produce
/// Inbox Captures, clarified Outcomes, or both, and a fully-cleared Inbox must
/// still keep the card dismissed. Watching only `todos` would leave the
/// onboarding CTA wrongly visible over an inbox-only import.
final hasAnyItemProvider = StreamProvider<bool>((ref) {
  final db = ref.watch(databaseProvider);
  return db.captureDao.watchHasAnyItem();
});
