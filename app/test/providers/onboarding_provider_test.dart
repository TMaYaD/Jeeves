import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/providers/onboarding_provider.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    onboardingSeenNotifier.value = false;
  });

  tearDown(() {
    onboardingSeenNotifier.value = false;
  });

  test('initOnboardingCompletion reads false on a clean prefs store', () async {
    await initOnboardingCompletion();
    expect(onboardingSeenNotifier.value, isFalse);
  });

  test('markOnboardingSeen flips notifier and persists to prefs', () async {
    await markOnboardingSeen();
    expect(onboardingSeenNotifier.value, isTrue);

    // Verify subsequent init picks up the persisted value.
    onboardingSeenNotifier.value = false;
    await initOnboardingCompletion();
    expect(onboardingSeenNotifier.value, isTrue);
  });

  test('initOnboardingCompletion reads true when prefs already set', () async {
    SharedPreferences.setMockInitialValues({'onboarding_seen': true});
    await initOnboardingCompletion();
    expect(onboardingSeenNotifier.value, isTrue);
  });

  test('initOnboardingCompletion reads false when prefs set to false', () async {
    SharedPreferences.setMockInitialValues({'onboarding_seen': false});
    await initOnboardingCompletion();
    expect(onboardingSeenNotifier.value, isFalse);
  });
}
