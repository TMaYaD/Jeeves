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

/// Bounded attempts for the synced write of the dismissal, and the pause
/// between them. A transient database failure must not strand the dismissal on
/// this device, and an endless retry must not spin.
const _kMaxWriteAttempts = 3;
const _kWriteRetryDelay = Duration(seconds: 1);

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

  /// Writes the dismissal to synced preferences, retrying a bounded number of
  /// times. Returns `true` when the write landed.
  ///
  /// The card stays hidden on this device either way: the dismissal is
  /// permanent here, and the next reconcile writes it again.
  Future<bool> writeDismissal() async {
    for (var attempt = 1; attempt <= _kMaxWriteAttempts; attempt++) {
      try {
        await syncedPrefs(ref).set(_kOnboardingSeenKey, true);
        return true;
      } catch (_) {
        if (attempt == _kMaxWriteAttempts) {
          debugPrint(
              'onboardingSyncProvider: the dismissal did not reach synced '
              'preferences after $attempt attempts');
          return false;
        }
        await Future<void>.delayed(_kWriteRetryDelay);
        if (!ref.mounted) return false;
      }
    }
    return false;
  }

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
      writeDismissal().then((landed) {
        if (!ref.mounted) return;
        writing = false;
        // The account can change while the write is in flight, and the write
        // can land for the account that has just been left. Reconciling again
        // writes the dismissal for whichever account is current now.
        if (landed) reconcile();
      });
    }
  }

  ref.listen(syncedPreferencesProvider, (_, _) => reconcile());
  ref.listen(currentUserIdProvider, (_, _) => reconcile());
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
