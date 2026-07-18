/// State management for the first-launch onboarding card (Issue #250).
///
/// Dismissal is permanent (not date-keyed) because onboarding is a one-time
/// event, unlike the daily planning banner.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_provider.dart';

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
