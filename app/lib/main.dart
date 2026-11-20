import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'capture/share_inbox_host.dart';
import 'database/store_refusal_error.dart';
import 'database/store_schema.dart';
import 'providers/auth_provider.dart';
import 'providers/database_provider.dart';
import 'providers/time_context_provider.dart';
import 'providers/nudge_action_outbox.dart';
import 'providers/onboarding_provider.dart';
import 'providers/sync_lifecycle_provider.dart';
import 'providers/sync_stack_provider.dart';
import 'providers/vault_sync_provider.dart';
import 'router.dart';
import 'screens/store_blocked/store_blocked_copy.dart';
import 'screens/store_blocked/store_blocked_screen.dart';
import 'screens/store_blocked/store_too_new_copy.dart';
import 'screens/store_blocked/store_unreadable_copy.dart';
import 'services/due_date_notifications.dart';
import 'services/follow_up_notifications.dart';
import 'services/legacy_sprint_prefs_cleanup.dart';
import 'services/notification_background_entry_point.dart';
import 'services/notification_service.dart';
import 'services/nudge_notification_scheduler.dart';
import 'services/ritual_notification_response_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final storeVersions = await prepareStartup();

  runApp(
    ProviderScope(
      overrides: [
        // The gate already read the two files; the providers use what it read
        // rather than reading them again.
        localStoreVersionsProvider.overrideWith((ref) async => storeVersions),
      ],
      child: JeevesApp(storeVersions: storeVersions),
    ),
  );
}

/// Everything the app does before its first frame.
///
/// Split out of [main] so the startup path can be exercised by a test. The
/// journey over the blocking screen starts at [JeevesApp] and so never went
/// through this code — and this is where the notification callbacks are
/// registered, which is where a background callback the plugin cannot resolve
/// stops the app from starting at all.
Future<LocalStoreVersions> prepareStartup() async {
  // Seed onboarding dismissal state before the first frame.
  await initOnboardingCompletion();
  await removeLegacySprintPrefs();

  // **The startup gate.** Read the two local stores' schema versions before
  // anything opens them: a store written by a newer build is left exactly as
  // it is, and the app says so instead of opening it. The read happens here,
  // before the first frame, so the verdict is known before anything can open a
  // store — and the provider is overridden with it, so the two files are read
  // once per launch.
  final storeVersions = await readLocalStoreVersions();

  // flutter_local_notifications uses platform channels unavailable on web.
  // Skip the entire notification stack on web; push notifications are a
  // separate feature (PWA Web Push) tracked outside this issue.
  if (!kIsWeb) {
    await registerNotificationCallbacks(storeVersions: storeVersions);
  }

  return storeVersions;
}

/// Registers the plugin's callbacks and asks for the permission to notify.
///
/// **The background callback is a top-level function, and it has to be.** The
/// plugin resolves it by callback handle and calls it from the engine it starts
/// for a background action; a closure that captures anything has no handle,
/// and the plugin fails to start the app when it is given one. The foreground
/// callback may be a closure: it runs on this isolate.
Future<void> registerNotificationCallbacks({
  required LocalStoreVersions storeVersions,
}) async {
  await NotificationService.initialize(
    onNotificationResponse: (response) => _handleNotificationResponse(
      response,
      storeVersions: storeVersions,
    ),
    onBackgroundNotificationResponse: handleBackgroundNotificationResponse,
  );
  await NotificationService.instance.requestPermissions();

  // Cold-start: if the user tapped a notification to launch the app from a
  // terminated state, onDidReceiveNotificationResponse will not fire; the
  // launch details must be fetched explicitly and dispatched.
  final launchDetails = await NotificationService.instance.getLaunchDetails();
  if (launchDetails?.didNotificationLaunchApp == true &&
      launchDetails?.notificationResponse != null) {
    _handleNotificationResponse(
      launchDetails!.notificationResponse!,
      storeVersions: storeVersions,
    );
  }
}

/// The foreground plugin callback for notification taps and action buttons.
/// The logic lives in [handleRitualNotificationResponse]; this binds it to the
/// real plugin and router.
///
/// **A store this build cannot open is not this build's to act on:** the
/// handler records a Nudge's dismissal or snooze in the very store this build
/// cannot read, so it does nothing at all.
///
/// The background callback is a different function —
/// `notification_background_entry_point.dart`'s — because the plugin resolves
/// that one by callback handle, which a closure that captures anything does
/// not have.
void _handleNotificationResponse(
  NotificationResponse response, {
  required LocalStoreVersions storeVersions,
}) {
  if (storeVersions.refusal != null) return;
  unawaited(handleRitualNotificationResponse(
    response,
    service: NotificationService.instance,
    navigate: appRouter.go,
  ));
}

/// The words the blocking screen says, for the reason the build cannot open
/// the stores.
///
/// A store written by a newer build gets the too-new words. A store this build
/// cannot read at all gets its own words, because nothing here knows whether
/// that store belongs to a newer Jeeves, and the screen must not say so.
StoreBlockedCopy _blockingCopyFor(StoreRefusalError refusal) {
  if (refusal is StoreVersionTooNewError) return storeTooNewCopy;
  return storeUnreadableCopy;
}

class JeevesApp extends ConsumerWidget {
  const JeevesApp({super.key, required this.storeVersions});

  /// What the two local store files carried when the app started.
  ///
  /// Read by the startup gate before the first frame, so the verdict is known
  /// before any provider can open a store.
  final LocalStoreVersions storeVersions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // **A store this build cannot open is left alone.** The check comes
    // before every provider below, so nothing opens a store, and the app says
    // what happened instead of showing an empty or broken home screen.
    final refusal = storeVersions.refusal;
    if (refusal != null) {
      return MaterialApp(
        title: 'Jeeves',
        theme: _jeevesTheme,
        home: StoreBlockedScreen(copy: _blockingCopyFor(refusal)),
      );
    }

    // Eagerly materialise [domainStoreRebuildProvider] so a device whose domain
    // store has not yet been replayed into replays its local op log now — first
    // launch after the cutover, or any launch after one that failed part-way.
    // Read first, and before anything that reads the store, so the replay starts
    // as early as the app can start it; it is not awaited (see the provider's own
    // note on why the view notifies make that safe), and a failure is logged
    // there rather than surfaced here, since there is no UI that could act on it.
    ref.watch(syncHostProvider);
    ref.watch(domainStoreRebuildProvider);
    // Runs once after the v4 upgrade, after the replay above (issue #238).
    ref.watch(timeContextTagConversionProvider);

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
    // The same for Waiting For follow-up dates (09:00 on the date).
    ref.watch(followUpNotificationReconcilerProvider);
    // Keeps the Ritual notifications equal to the projection of the Nudge
    // queue over the coming week. Nothing else reads it.
    ref.watch(nudgeNotificationSchedulerProvider);
    // Keeps the first-launch card dismissal in step across devices.
    ref.watch(onboardingSyncProvider);
    // Materialises the vault plugin when this device has a vault folder set,
    // so the folder is read again while the app is open. Nothing else reads
    // it, and without this watch the vault would only run while a screen that
    // reads it was open.
    ref.watch(vaultPluginProvider);
    return MaterialApp.router(
      title: 'Jeeves',
      theme: _jeevesTheme,
      routerConfig: appRouter,
      // Only Android has a share-sheet receiver that queues shares.
      builder: (context, child) =>
          !kIsWeb && defaultTargetPlatform == TargetPlatform.android
              ? ShareInboxHost(child: child ?? const SizedBox.shrink())
              : child ?? const SizedBox.shrink(),
    );
  }
}

/// The app's theme, shared by the router's app and by the blocking screen the
/// startup gate shows in its place.
final ThemeData _jeevesTheme = ThemeData(
  colorSchemeSeed: const Color(0xFF2667B7),
  useMaterial3: true,
  fontFamily: 'Manrope',
  scaffoldBackgroundColor: Colors.white,
);
