import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'capture/share_inbox_host.dart';
import 'providers/auth_provider.dart';
import 'providers/database_provider.dart';
import 'providers/focus_session_planning_settings_provider.dart';
import 'providers/nudge_action_outbox.dart';
import 'providers/onboarding_provider.dart';
import 'providers/sync_lifecycle_provider.dart';
import 'providers/shutdown_settings_provider.dart';
import 'router.dart';
import 'services/due_date_notifications.dart';
import 'services/notification_service.dart';
import 'services/ritual_notification_response_handler.dart';

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

/// Plugin callback for notification taps and action buttons. The logic lives in
/// [handleRitualNotificationResponse]; this binds it to the real plugin and
/// router.
///
/// The `@pragma('vm:entry-point')` annotation keeps this function alive in
/// release builds so the OS can call it when the app is in the background.
@pragma('vm:entry-point')
void _handleNotificationResponse(NotificationResponse response) {
  unawaited(handleRitualNotificationResponse(
    response,
    service: NotificationService.instance,
    navigate: appRouter.go,
  ));
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
    // Keeps a notification scheduled for each due-dated Outcome (09:00 on its
    // due day). Nothing else reads it, so without this watch it never runs.
    ref.watch(dueDateNotificationReconcilerProvider);
    return MaterialApp.router(
      title: 'Jeeves',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2667B7),
        useMaterial3: true,
        fontFamily: 'Manrope',
        scaffoldBackgroundColor: Colors.white,
      ),
      routerConfig: appRouter,
      // Only Android has a share-sheet receiver that queues shares.
      builder: (context, child) =>
          !kIsWeb && defaultTargetPlatform == TargetPlatform.android
              ? ShareInboxHost(child: child ?? const SizedBox.shrink())
              : child ?? const SizedBox.shrink(),
    );
  }
}
