import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'providers/auth_provider.dart';
import 'providers/daily_planning_provider.dart';
import 'providers/evening_shutdown_provider.dart';
import 'providers/planning_settings_provider.dart';
import 'providers/shutdown_settings_provider.dart';
import 'router.dart';
import 'services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Seed suppression flags before any notification scheduling so that a
  // previously skipped/snoozed reminder is not re-enabled on restart.
  await initPlanningCompletion();
  await loadNotificationSuppression();

  // Seed shutdown state from SharedPreferences before the first frame.
  await initShutdownCompletion();
  await loadShutdownNotificationSuppression();

  // flutter_local_notifications uses platform channels unavailable on web.
  // Skip the entire notification stack on web; push notifications are a
  // separate feature (PWA Web Push) tracked outside this issue.
  if (!kIsWeb) {
    // Initialize notification service with the action handler registered
    // before any notification can fire (including cold-start launch).
    await NotificationService.initialize(
      onNotificationResponse: _handleNotificationResponse,
    );
    await NotificationService.instance.requestPermissions();

    // Re-establish the daily planning notification schedule after a restart.
    await initPlanningNotificationSchedule();

    // Re-establish the evening shutdown notification schedule after a restart.
    await initShutdownNotificationSchedule();

    // Cold-start: if the user tapped a notification to launch the app from a
    // terminated state, onDidReceiveNotificationResponse will not fire; the
    // launch details must be fetched explicitly and dispatched.
    final launchDetails = await NotificationService.instance.getLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp == true &&
        launchDetails?.notificationResponse != null) {
      _handleNotificationResponse(launchDetails!.notificationResponse!);
    }
  }

  runApp(const ProviderScope(child: JeevesApp()));
}

/// Handles taps on planning notification actions (foreground and background).
///
/// The `@pragma('vm:entry-point')` annotation keeps this function alive in
/// release builds so the OS can call it when the app is in the background.
@pragma('vm:entry-point')
void _handleNotificationResponse(NotificationResponse response) async {
  final actionId = response.actionId;

  switch (actionId) {
    case kNotificationActionOpen:
    case null:
      // Null actionId means the notification body was tapped — both cases
      // navigate to the planning ritual.
      appRouter.go('/planning');

    case kNotificationActionSnooze:
      // Read snooze duration directly from SharedPreferences; Riverpod is not
      // available in background-isolate notification callbacks.
      final snoozeMins = await _readDefaultSnoozeDuration();
      final until = DateTime.now().add(Duration(minutes: snoozeMins));
      await persistSnoozedUntil(until);
      await NotificationService.instance.snoozePlanningReminder(snoozeMins);

    case kNotificationActionSkip:
      await persistSkipToday();
      await NotificationService.instance.cancelPlanningReminder();

    case kShutdownNotificationActionOpen:
      appRouter.go('/shutdown');

    case kShutdownNotificationActionSnooze:
      final until = DateTime.now().add(const Duration(minutes: 60));
      await persistShutdownSnoozedUntil(until);
      await NotificationService.instance.snoozeShutdownReminder(60);

    case kShutdownNotificationActionSkip:
      await persistShutdownSkipToday();
      await NotificationService.instance.cancelShutdownReminder();
  }
}

Future<int> _readDefaultSnoozeDuration() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getInt('planning_settings_default_snooze_duration') ?? 60;
}

class JeevesApp extends ConsumerWidget {
  const JeevesApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Eagerly materialise [authTokenProvider] so its async build() runs at
    // startup and restores the persisted session from secure storage.  The
    // provider is lazy — without this, stored tokens are ignored until the
    // user opens a screen that reads it (login, settings), and the app
    // appears signed out across restarts.
    ref.watch(authTokenProvider);
    return MaterialApp.router(
      title: 'Jeeves',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2667B7),
        useMaterial3: true,
        fontFamily: 'Manrope',
        scaffoldBackgroundColor: Colors.white,
      ),
      routerConfig: appRouter,
    );
  }
}
