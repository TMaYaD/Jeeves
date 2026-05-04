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

/// True if the user's database contains at least one todo of any kind.
///
/// Watches all todos, not just inbox items, so that Nirvana imports
/// (which produce clarified todos) also hide the onboarding card.
final hasTodosProvider = StreamProvider<bool>((ref) {
  final db = ref.watch(databaseProvider);
  final userId = ref.watch(currentUserIdProvider);
  return db.inboxDao.watchHasTodos(userId);
});
