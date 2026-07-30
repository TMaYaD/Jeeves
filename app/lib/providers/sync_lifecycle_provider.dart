/// Starts syncing: the one provider that turns an enrolled store into a syncing
/// device.
///
/// Eagerly watched from `main.dart`, like [postSyncHooksProvider], because a lazy
/// provider is a lifecycle that never runs — nothing else reads it, so nothing
/// else would build it, and a relaunched enrolled device would sit with its keys
/// and no transport until the user happened to open the enrolment screen.
///
/// It activates on build and deactivates when the signed-in user changes: the
/// stack is derived from the account (Workspace ids, escrow slot and Grants all
/// are), so a sign-out has to stop authoring rather than keep a bound seam
/// pointing at the previous account's log.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sync/sync_lifecycle.dart';
import 'auth_provider.dart';
import 'database_provider.dart';
import 'sync_stack_provider.dart';
import 'user_constants.dart';

/// The device's sync lifecycle, or null while no account is signed in.
///
/// Null rather than a throwing provider: `syncStackProvider` refuses the
/// `'local'` placeholder — a Workspace id is `uuid5` of the user id, so enrolling
/// as `'local'` would mint an escrow under an id no account owns — and "there is
/// nobody to sync for" is an ordinary state, not an error to surface.
final syncLifecycleProvider = FutureProvider<SyncLifecycle?>((ref) async {
  ref.keepAlive();
  final userId = ref.watch(currentUserIdProvider);
  if (userId == kLocalUserId) return null;

  final lifecycle = SyncLifecycle(
    stack: await ref.watch(syncStackProvider.future),
    domain: ref.watch(databaseProvider),
    capture: ref.watch(domainOpCaptureProvider),
  );
  ref.onDispose(() => unawaited(lifecycle.deactivate()));

  // Not awaited: the provider's job is to *have* a lifecycle, and the first
  // activation includes a network round trip and possibly a walk of the whole
  // store. Anything that reads this provider would otherwise block on the upload.
  unawaited(activateAndLog(lifecycle));
  return lifecycle;
});

/// Run an activation and say what happened, swallowing nothing quietly.
///
/// Every outcome is either "the device is syncing" or a state the *next*
/// activation retries, so there is nothing here for a user to act on and nothing
/// worth an error surface: an un-enrolled device is the normal offline case, and
/// a failed sync or an incomplete upload is retried by the next poke, the next
/// authored op or the next launch. What must not happen is silence.
Future<void> activateAndLog(SyncLifecycle lifecycle) async {
  try {
    debugPrint('sync lifecycle: ${(await lifecycle.activate()).name}');
  } catch (error) {
    // Only a failure the sequence does not classify reaches here — a failed sync
    // and an incomplete upload are outcomes rather than throws. Caught because
    // this runs un-awaited: an escaping error would be an unhandled async
    // exception with nobody to attribute it to.
    debugPrint('sync lifecycle: activation failed — $error');
  }
}
