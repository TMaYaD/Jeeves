/// The sync indicator's one adapter, over the op-log spine.
///
/// It reads `SyncHealth` — outbox depth, unresolved integrity alarms, quarantined
/// ops — from **both** of the device's Workspace clients, because a device is two
/// Workspaces of one User and a wedged preferences queue is a wedged device.
///
/// It deliberately does *not* read PowerSync's status stream any more. The engine
/// no longer connects (#591), so that stream sits permanently idle and would map
/// to `synced` — an indicator reading green over a device that is not syncing at
/// all, during the one window where the user most needs the truth. The
/// dead-letter watch goes for the matching reason: nothing uploads through the
/// connector, so no new dead letter can be recorded, and the table itself rides
/// #556 (ADR-0030's parking).
///
/// Still **informational, never blocking** (docs/ARCHITECTURE.md § the two-stage
/// boundary): behaviour must not depend on this value.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sync/enrolment_state.dart';
import '../sync/sync_health.dart';
import 'auth_provider.dart';
import 'sync_lifecycle_provider.dart';
import 'sync_stack_provider.dart';
import 'user_constants.dart';

enum SyncStatus { localOnly, connecting, syncing, synced, error }

/// The status two Workspaces' health adds up to, given what the store says about
/// enrolment and whether a member credential is in hand.
///
/// Pure, so the table is asserted directly rather than through a staged device.
/// Worst news first: an accusation that still stands, or an op this device refused
/// to apply, outranks a queue that is merely busy.
SyncStatus syncStatusFor({
  required EnrolmentState enrolment,
  required bool hasMemberCredential,
  required Iterable<SyncHealth> health,
}) {
  // A device that has not finished enrolling has no log to sync with. That is the
  // ordinary offline case, not a degraded one.
  if (enrolment != EnrolmentState.enrolled) return SyncStatus.localOnly;
  if (health.any((one) => one.degraded)) return SyncStatus.error;
  // Enrolled, and the credential has not been re-minted yet — the window between
  // launch and the lifecycle's proof-of-possession exchange.
  if (!hasMemberCredential) return SyncStatus.connecting;
  if (health.any((one) => one.pendingOpCount > 0)) return SyncStatus.syncing;
  return SyncStatus.synced;
}

/// Stream of the current sync status.
///
/// [SyncStatus.localOnly] while nobody is signed in, and while a signed-in device
/// has not finished enrolling.
final syncStatusProvider = StreamProvider<SyncStatus>((ref) async* {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == kLocalUserId) {
    yield SyncStatus.localOnly;
    return;
  }

  // Watched rather than merely read so the indicator exists on a device that has
  // never enrolled — the lifecycle is null only for the `'local'` placeholder,
  // which the branch above has already handled.
  await ref.watch(syncLifecycleProvider.future);
  final stack = await ref.watch(syncStackProvider.future);

  final controller = StreamController<SyncStatus>();
  final health = <String, SyncHealth>{};
  SyncStatus? lastEmitted;

  // Every failure lands on the stream, because most emissions are un-awaited
  // (below): a throw from the enrolment read would otherwise be an unhandled
  // async error and the indicator would sit frozen on its last status — the one
  // failure mode this rewrite exists to prevent. Same treatment the health
  // streams' own `onError` gets.
  Future<void> emit() async {
    if (controller.isClosed) return;
    try {
      // Re-read enrolment on every emission rather than once: a device that
      // enrols *while the indicator is on screen* must stop saying "local only",
      // and the ceremony's own pull stamps `sync_cursors.last_sync_completed_at`,
      // which is one of the columns the health query watches — so the tick
      // arrives.
      final next = syncStatusFor(
        enrolment: (await stack.readEnrolmentStatus()).state,
        hasMemberCredential: stack.defaultClient.isEnrolled,
        health: health.values,
      );
      if (controller.isClosed || next == lastEmitted) return;
      lastEmitted = next;
      controller.add(next);
    } on Object catch (error, stackTrace) {
      if (!controller.isClosed) controller.addError(error, stackTrace);
    }
  }

  final subscriptions = <StreamSubscription<SyncHealth>>[];
  for (final workspaceId in stack.workspaceIds) {
    final client = await stack.workspaceClientFactory(workspaceId);
    subscriptions.add(client.watchSyncHealth().listen(
          (value) {
            health[workspaceId] = value;
            unawaited(emit());
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!controller.isClosed) controller.addError(error, stackTrace);
          },
        ));
  }
  ref.onDispose(() {
    for (final subscription in subscriptions) {
      subscription.cancel();
    }
    controller.close();
  });

  // Seeded, because the watch streams emit on *change*: a subscriber attaching to
  // a settled device would otherwise stay in `AsyncLoading` for ever and the UI
  // would sit on its "local only" fallback.
  await emit();
  yield* controller.stream;
});
