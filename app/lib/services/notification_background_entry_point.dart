/// The plugin's background notification callback.
///
/// The plugin starts a separate Flutter engine for it when the user taps an
/// action button on a notification while the app is not running, so this file
/// holds the one function that engine can call.
library;

import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../database/store_schema.dart';
import 'notification_service.dart';
import 'ritual_notification_response_handler.dart';

/// The callback the plugin calls when the user taps an action button on a
/// notification while the app is not running.
///
/// **It has to be a top-level function.** The plugin resolves it by callback
/// handle and calls it from the engine it starts, and only a top-level or
/// static function has a handle: a closure that captures anything has none,
/// and the plugin asserts on it in debug and dereferences a null handle in
/// release — so the app never starts at all. The `@pragma('vm:entry-point')`
/// annotation keeps the function in a release build, where nothing else would
/// keep it.
///
/// **It checks the stores for itself.** A background isolate has no Riverpod
/// container and no memory of the launch that started it, so it reads the two
/// store files itself before it does anything. A store written by a newer
/// build is not this build's to act on: the handler records what the user did
/// in the very store this build cannot read, so an unreadable store refuses
/// the action as firmly as a newer one does.
@pragma('vm:entry-point')
void handleBackgroundNotificationResponse(NotificationResponse response) {
  unawaited(handleBackgroundNotificationAction(response));
}

/// The background action, start to finish: the paired-store check, and only
/// then the work.
///
/// The plugin calls [handleBackgroundNotificationResponse] and does not wait
/// for it — the engine that runs it is gone by the time the work is done — so
/// the work lives in a function that can be awaited, and a test can await it
/// too.
Future<void> handleBackgroundNotificationAction(
    NotificationResponse response) async {
  final storeVersions = await readLocalStoreVersions();
  if (storeVersions.refusal != null) return;
  await handleRitualNotificationResponse(
    response,
    service: NotificationService.instance,
    navigate: _noNavigation,
  );
}

/// A background isolate has no router and no screen.
///
/// The actions that reach a background isolate are the ones that do their work
/// on the OS and in the outbox — Skip and Snooze — and neither of them
/// navigates. An action that would open a screen is delivered to the main
/// isolate instead, which has the router.
void _noNavigation(String route) {}
