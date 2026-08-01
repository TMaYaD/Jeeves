import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/ritual.dart';
import 'providers/auth_provider.dart';
import 'providers/database_provider.dart';
import 'providers/evening_shutdown_provider.dart';
import 'providers/focus_session_planning_provider.dart';
import 'providers/focus_session_planning_settings_provider.dart';
import 'providers/onboarding_provider.dart';
import 'providers/periodic_review_settings_provider.dart';
import 'providers/sync_lifecycle_provider.dart';
import 'providers/shutdown_settings_provider.dart';
import 'router.dart';
import 'services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Seed onboarding dismissal state before the first frame.
  await initOnboardingCompletion();

  // Seed notification-suppression flags before any scheduling so that a
  // previously skipped/snoozed reminder is not re-enabled on restart.
  await loadFocusSessionPlanningNotificationSuppression();
  await loadShutdownNotificationSuppression();

  // Seed periodic-review notification suppression so a previously skipped/
  // snoozed reminder is not re-enabled on restart.
  await loadPeriodicReviewNotificationSuppression();

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
    await initFocusSessionPlanningNotificationSchedule();

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
      // Null actionId means the notification body was tapped. Route by
      // payload — focus/sprint carries 'focus', Ritual notifications carry
      // `nudge:<keyPrefix>` and resolve to the matching wizard route. A
      // body tap on an unknown payload falls back to inbox.
      if (response.payload == 'focus') {
        appRouter.go('/focus/active');
      } else {
        final ritual = ritualIdFromNotificationPayload(response.payload);
        appRouter.go(ritual != null
            ? ritualNotificationRoute(ritual)
            : '/inbox');
      }

    case kNotificationActionSnooze:
      // Read snooze duration directly from SharedPreferences; Riverpod is not
      // available in background-isolate notification callbacks.
      final snoozeMins = await _readDefaultSnoozeDuration();
      final until = DateTime.now().add(Duration(minutes: snoozeMins));
      await persistFocusSessionPlanningSnoozedUntil(until);
      await NotificationService.instance
          .snoozeRitualReminder(RitualId.dailyPlanning, snoozeMins);

    case kNotificationActionSkip:
      await persistFocusSessionPlanningSkipToday();
      await NotificationService.instance
          .skipTodayRitualReminder(RitualId.dailyPlanning);

    case kShutdownNotificationActionOpen:
      appRouter.go('/shutdown');

    case kShutdownNotificationActionSnooze:
      final until = DateTime.now().add(const Duration(minutes: 60));
      await persistShutdownSnoozedUntil(until);
      await NotificationService.instance
          .snoozeRitualReminder(RitualId.eveningShutdown, 60);

    case kShutdownNotificationActionSkip:
      await persistShutdownSkipToday();
      await NotificationService.instance
          .skipTodayRitualReminder(RitualId.eveningShutdown);

    case kPeriodicReviewActionOpen:
      appRouter.go('/periodic-review');

    case kPeriodicReviewActionSnooze:
      final until = DateTime.now().add(const Duration(minutes: 60));
      await persistPeriodicReviewSnoozedUntil(until);
      await NotificationService.instance
          .snoozeRitualReminder(RitualId.weeklyReview, 60);

    case kPeriodicReviewActionSkip:
      await persistPeriodicReviewSkipToday();
      await NotificationService.instance
          .skipTodayRitualReminder(RitualId.weeklyReview);
  }
}

Future<int> _readDefaultSnoozeDuration() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getInt('focus_session_planning_settings_default_snooze_duration') ?? 60;
}

class JeevesApp extends ConsumerWidget {
  const JeevesApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Eagerly materialise [domainStoreRebuildProvider] so a device whose domain
    // store has not yet been replayed into replays its local op log now — first
    // launch after the cutover, or any launch after one that failed part-way.
    // Read first, and before anything that reads the store, so the replay starts
    // as early as the app can start it; it is not awaited (see the provider's own
    // note on why the ADR-0010 notifies make that safe), and a failure is logged
    // there rather than surfaced here, since there is no UI that could act on it.
    ref.watch(domainStoreRebuildProvider);

    // Eagerly materialise [authTokenProvider] so its async build() runs at
    // startup and restores the persisted session from secure storage.  The
    // provider is lazy — without this, stored tokens are ignored until the
    // user opens a screen that reads it (login, settings), and the app
    // appears signed out across restarts.
    ref.watch(authTokenProvider);

    // Eagerly materialise [syncLifecycleProvider] so an enrolled device starts
    // syncing at launch: it re-mints its member credential, resumes an
    // interrupted initial upload and subscribes.  Nothing else reads it, so
    // without this read it stays lazy and the device never syncs.
    ref.watch(syncLifecycleProvider);
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
