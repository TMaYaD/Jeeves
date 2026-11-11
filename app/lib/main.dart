import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/ritual.dart';
import 'providers/auth_provider.dart';
import 'providers/database_provider.dart';
import 'providers/focus_session_planning_settings_provider.dart';
import 'providers/nudge_action_outbox.dart';
import 'providers/onboarding_provider.dart';
import 'providers/sync_lifecycle_provider.dart';
import 'providers/shutdown_settings_provider.dart';
import 'router.dart';
import 'services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Seed onboarding dismissal state before the first frame.
  await initOnboardingCompletion();

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

/// Handles taps on Ritual notification actions (foreground and background).
///
/// Open and a body tap route to the Ritual's wizard. Skip and Snooze do their
/// immediate OS work (cancel / re-arm the one-off alarm) and record what the
/// user did, and when, in the Nudge action outbox. The outbox is applied to
/// the Nudge's dismiss / snooze state by the main isolate — this function may
/// run in a background isolate with no Riverpod container and no database.
///
/// The `@pragma('vm:entry-point')` annotation keeps this function alive in
/// release builds so the OS can call it when the app is in the background.
@pragma('vm:entry-point')
void _handleNotificationResponse(NotificationResponse response) async {
  final actionId = response.actionId;
  final ritualAction = ritualNotificationActionFor(actionId);

  if (ritualAction == null || ritualAction.kind == RitualNotificationActionKind.open) {
    // Null actionId means the notification body was tapped. Route by
    // payload — focus/sprint carries 'focus', Ritual notifications carry
    // `nudge:<keyPrefix>` and resolve to the matching wizard route. A
    // body tap on an unknown payload falls back to inbox.
    if (ritualAction != null) {
      appRouter.go(ritualNotificationRoute(ritualAction.ritual));
    } else if (actionId == null) {
      if (response.payload == 'focus') {
        appRouter.go('/focus/active');
      } else {
        final ritual = ritualIdFromNotificationPayload(response.payload);
        appRouter.go(ritual != null
            ? ritualNotificationRoute(ritual)
            : '/inbox');
      }
    }
    return;
  }

  final ritual = ritualAction.ritual;
  final snoozeMinutes = ritualAction.kind == RitualNotificationActionKind.snooze &&
          ritual == RitualId.dailyPlanning
      // Read snooze duration directly from SharedPreferences; Riverpod is not
      // available in background-isolate notification callbacks.
      ? await _readDefaultSnoozeDuration()
      : 60;
  await recordRitualNotificationAction(
    ritual: ritual,
    kind: ritualAction.kind,
    at: DateTime.now(),
    snoozeMinutes: snoozeMinutes,
  );
  if (ritualAction.kind == RitualNotificationActionKind.snooze) {
    await NotificationService.instance.snoozeRitualReminder(ritual, snoozeMinutes);
  } else {
    await NotificationService.instance.skipTodayRitualReminder(ritual);
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
    // note on why the view notifies make that safe), and a failure is logged
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

    // Eagerly materialise [nudgeActionOutboxDrainerProvider] so Skip / Snooze
    // taps recorded by the notification handler (possibly in a background
    // isolate) reach the Nudge's dismiss / snooze state, and live legacy
    // suppression is carried over once.
    ref.watch(nudgeActionOutboxDrainerProvider);
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
