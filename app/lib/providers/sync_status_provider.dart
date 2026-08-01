/// The sync indicator's one adapter, over the op-log spine.
///
/// It reads `SyncHealth` — outbox depth, unresolved integrity alarms, quarantined
/// ops — from **both** of the device's Workspace clients, because a device is two
/// Workspaces of one User and a wedged preferences queue is a wedged device.
///
/// It reads nothing else, and that is the point. The storage engine it used to
/// read a status stream from is gone (#591, #595); while that engine sat
/// connected-to-nothing the stream mapped to `synced`, an indicator reading green
/// over a device that was not syncing at all — during the one window where the
/// user most needs the truth. The dead-letter count it also used to fold in went
/// with the uploader that wrote it.
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

enum SyncStatus {
  localOnly,
  connecting,
  syncing,
  synced,

  /// Visible, non-red, nothing to do: there is an account of what happened worth
  /// reading, and none of it needs the User.
  ///
  /// **Named for what the User is told, not for our model** — not `reported`,
  /// not `informational`, both of which name the classification rather than the
  /// message. It is the same phrase as the indicator's tooltip and as the
  /// screen's own explanation, so the enum member, the tooltip and the sentence
  /// are one idea in three places.
  ///
  /// It exists because the alternative was worse: fourteen of the eighteen alarm
  /// kinds live in this band, and if it looked identical to healthy the entry
  /// point would be a secret rather than a surface.
  worthKnowing,

  error,
}

/// Everything the drawer indicator needs, from one read.
///
/// The tappability and the glyph come out of the **same** value deliberately:
/// two providers over the same health would be two subscriptions, free to
/// disagree about whether there is anything behind the tile the user just
/// tapped.
typedef SyncIndication = ({SyncStatus status, bool hasSomethingToReport});

/// What two Workspaces' health adds up to, given what the store says about
/// enrolment and whether a member credential is in hand.
///
/// Pure, so the table is asserted directly rather than through a staged device.
///
/// **Worst *undecided* news first.** The order is:
///
/// ```
/// 1. not enrolled                                   -> localOnly
/// 2. ANY workspace has an undecided actionable alarm -> error
/// 3. no member credential                            -> connecting
/// 4. ANY workspace pendingOpCount > 0                -> syncing
/// 5. ANY workspace hasSomethingToReport              -> worthKnowing
/// 6. otherwise                                       -> synced
/// ```
///
/// Row 2 is stated as *any* Workspace because a two-Workspace bug is invisible
/// to a single-Workspace test: **one Workspace in the calm band beside another
/// holding an undecided actionable alarm renders as the error.** Calm news must
/// never mask a condition nobody has looked at.
///
/// `syncing` sits above `worthKnowing` on purpose — a flush in progress is
/// transient and more informative in the moment, and the calm state will still
/// be there when it drains, since it is the resting state whenever there is
/// history to read.
SyncIndication syncIndicationFor({
  required EnrolmentState enrolment,
  required bool hasMemberCredential,
  required Iterable<SyncHealth> health,
}) {
  final hasSomethingToReport = health.any((one) => one.hasSomethingToReport);
  SyncStatus status() {
    // A device that has not finished enrolling has no log to sync with. That is
    // the ordinary offline case, not a degraded one.
    if (enrolment != EnrolmentState.enrolled) return SyncStatus.localOnly;
    if (health.any((one) => one.degraded)) return SyncStatus.error;
    // Enrolled, and the credential has not been re-minted yet — the window
    // between launch and the lifecycle's proof-of-possession exchange.
    if (!hasMemberCredential) return SyncStatus.connecting;
    if (health.any((one) => one.pendingOpCount > 0)) return SyncStatus.syncing;
    if (hasSomethingToReport) return SyncStatus.worthKnowing;
    return SyncStatus.synced;
  }

  // Reachability is the health's own answer, not the status's: `syncing` and
  // `connecting` outrank the calm state, and a tile that stopped being tappable
  // for the length of a flush would make the account of events look like it had
  // been withdrawn.
  return (status: status(), hasSomethingToReport: hasSomethingToReport);
}

/// The indicator's state alone. The pure table, asserted directly.
SyncStatus syncStatusFor({
  required EnrolmentState enrolment,
  required bool hasMemberCredential,
  required Iterable<SyncHealth> health,
}) =>
    syncIndicationFor(
      enrolment: enrolment,
      hasMemberCredential: hasMemberCredential,
      health: health,
    ).status;

/// Stream of the current sync indication — the status, and whether there is
/// anything behind the tile to open.
///
/// [SyncStatus.localOnly] while nobody is signed in, and while a signed-in device
/// has not finished enrolling.
final syncStatusProvider = StreamProvider<SyncIndication>((ref) async* {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == kLocalUserId) {
    yield (status: SyncStatus.localOnly, hasSomethingToReport: false);
    return;
  }

  // Watched rather than merely read so the indicator exists on a device that has
  // never enrolled — the lifecycle is null only for the `'local'` placeholder,
  // which the branch above has already handled.
  await ref.watch(syncLifecycleProvider.future);
  final stack = await ref.watch(syncStackProvider.future);

  final controller = StreamController<SyncIndication>();
  final health = <String, SyncHealth>{};
  SyncIndication? lastEmitted;

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
      final next = syncIndicationFor(
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
