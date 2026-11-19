/// Starts syncing: the one provider that turns an enrolled store into a syncing
/// device.
///
/// Eagerly watched from `main.dart`, like [domainStoreRebuildProvider], because a
/// lazy provider is a lifecycle that never runs — nothing else reads it, so nothing
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

import '../sync/host/hosted_capture.dart' show clearEnrolledMemberId;
import '../sync/sync_lifecycle.dart';
import 'auth_provider.dart';
import 'database_provider.dart';
import 'device_names_provider.dart';
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
  if (userId == kLocalUserId) {
    // A local-only user never builds a lifecycle, so nobody would ever *decide*
    // the capture seam — and the seam buffers from construction, so an
    // undecided seam grows for the session. Settle it silent, but only once
    // session restore has **answered**: while restore is in flight the user
    // still reads `'local'`, and that is exactly the enrolled-relaunch window
    // that must keep buffering until the real id arrives. The narrow `select`
    // keeps a token refresh from churning this provider.
    final restorePending =
        ref.watch(authTokenProvider.select((token) => token.isLoading));
    if (restorePending) return null;
    ref.watch(domainOpCaptureProvider).unbind();
    // A lifecycle would also have settled the stored member id, and none exists
    // here. A process killed while signed in never ran `deactivate()`, so the
    // previous account's member id can still be on the row — and every write made
    // signed out would be stamped with it while nothing authors it. Cleared on
    // the domain store directly, issued in this same turn: going through the
    // sync host would await its start between the decision and the write, and a
    // sign-in landing in that wait would have its freshly stored id wiped.
    final domain = ref.watch(databaseProvider);
    try {
      await clearEnrolledMemberId(domain);
    } catch (error) {
      // Not worth an error state: two status providers await this one.
      debugPrint('sync lifecycle: clearing the member id failed — $error');
    }
    // A signed-out device still has a name of its own, and it is written under
    // the local profile so that a later sign-in carries it into the account.
    // Not awaited: nothing waits on a name, and this provider's job here is to
    // have no lifecycle at all.
    unawaited(ref.read(deviceNamesProvider).ensureOwnNames(kLocalUserId));
    return null;
  }

  final deviceNames = ref.watch(deviceNamesProvider);
  final lifecycle = SyncLifecycle(
    stack: await ref.watch(syncStackProvider.future),
    domain: ref.watch(databaseProvider),
    capture: ref.watch(domainOpCaptureProvider),
    host: await ref.watch(syncHostProvider.future),
    // The device names itself once the activation has finished, never before:
    // the name is written to the preferences Workspace, and the activation is
    // what binds the capture that authors it.
    onActivationFinished: () => deviceNames.ensureOwnNames(userId),
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
