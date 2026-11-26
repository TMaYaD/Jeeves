/// The rows behind the sync-health screen, folded across both Workspaces.
///
/// It **derives no status.** The indicator reads `syncStatusProvider` and nothing
/// else, so this provider cannot become a second opinion about whether sync is
/// healthy — it only says what happened, and the one adapter licensed to source
/// sync state stays the one adapter (docs/ARCHITECTURE.md § the two-stage
/// boundary).
///
/// The fold itself is `syncHealthConditionsFor`, a pure function over the two
/// tables' rows: this provider is the subscription plumbing and nothing more, so
/// the mapping the screen depends on is testable without a live Drift `watch()`
/// under a widget (docs/TESTING.md).
///
/// The other half of this file is the seam the other way: [syncAlarmResolverProvider]
/// carries the user's decision back to the row behind a condition.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jeeves/sync/sync_database.dart';

import '../sync/alarm_resolution.dart';
import '../sync/sync_health_detail.dart';
import 'auth_provider.dart';
import 'sync_lifecycle_provider.dart';
import 'sync_stack_provider.dart';
import 'user_constants.dart';

/// Settles one condition: records the user's decision on the row behind it.
///
/// The one seam between the screen and the store. The screen decides *which*
/// decision the user made — it knows the kind and the row — and this function
/// carries it to the Workspace that holds the row. An accusation is settled on
/// the alarm; a refused change that stands on its own is settled on the change.
///
/// **Keeping ours is the one decision with work left to do.** On a rollback the
/// changes have to go back out, and the user should not have to wait for
/// something else to trigger the upload — so the flush is asked for here. On a
/// divergence this device's copy is already on the log and the flush is a
/// no-op, which is why the decision rather than the kind is what is asked
/// about.
typedef SyncAlarmResolver = Future<void> Function(
  SyncHealthCondition condition,
  AlarmResolution resolution,
);

/// Records the user's decision on the condition behind a row.
///
/// The stack and the lifecycle are read when the decision is made rather than
/// when the provider is built: a screen that is open but idle must not hold a
/// Workspace client, and a device with no account has no stack to ask.
final syncAlarmResolverProvider = Provider<SyncAlarmResolver>((ref) {
  return (condition, resolution) async {
    final stack = await ref.read(syncStackProvider.future);
    final client = await stack.workspaceClientFactory(condition.workspaceId);
    switch (condition.source) {
      case SyncConditionSource.standingCondition:
        await client.resolveAlarm(
          condition.rowId,
          resolution,
          // The accusation the User was shown, so one raised again since is
          // refused as a stale answer rather than answered by mistake.
          expectedOccurrenceCount: condition.occurrenceCount,
        );
      case SyncConditionSource.refusedItem:
        await client.resolveRefusedItem(condition.rowId, resolution);
    }
    if (resolution == AlarmResolution.keptOurs) {
      final lifecycle = await ref.read(syncLifecycleProvider.future);
      await lifecycle?.flushOutboxNow();
    }
  };
});

final syncHealthDetailProvider =
    StreamProvider<List<SyncHealthCondition>>((ref) async* {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == kLocalUserId) {
    yield const [];
    return;
  }

  final controller = StreamController<List<SyncHealthCondition>>();
  final alarms = <String, List<IntegrityAlarmRow>>{};
  final refusals = <String, List<QuarantineRow>>{};
  final subscriptions = <StreamSubscription<void>>[];

  // Registered **before the first `await`**. Riverpod does not cancel a
  // suspended async generator on dispose: the body resumes regardless, so a hook
  // registered after the awaits runs against a dead `ref` and throws
  // `UnmountedRefException` instead — leaving the subscriptions the body just
  // opened uncancelled and the controller unclosed. Two live Drift watches per
  // Workspace, leaked on every open-and-close of a screen the user did not wait
  // for.
  ref.onDispose(() {
    for (final subscription in subscriptions) {
      subscription.cancel();
    }
    controller.close();
  });

  // Checked after *every* await, not only the last: `ref` is unusable once the
  // element is gone, so a resumed body that reaches the next `ref.watch` throws
  // out of the generator rather than returning quietly.
  await ref.watch(syncLifecycleProvider.future);
  if (!ref.mounted) return;
  final stack = await ref.watch(syncStackProvider.future);
  if (!ref.mounted) return;

  void emit() {
    if (controller.isClosed) return;
    controller.add([
      for (final workspaceId in stack.workspaceIds)
        ...syncHealthConditionsFor(
          workspaceId: workspaceId,
          alarms: alarms[workspaceId] ?? const [],
          refusals: refusals[workspaceId] ?? const [],
        ),
    ]);
  }

  void fail(Object error, StackTrace stackTrace) {
    if (!controller.isClosed) controller.addError(error, stackTrace);
  }

  for (final workspaceId in stack.workspaceIds) {
    final client = await stack.workspaceClientFactory(workspaceId);
    // The factory is awaited per Workspace, so dispose can land between two of
    // them: check again rather than open a watch nothing will ever close.
    if (!ref.mounted) return;
    subscriptions.add(client.watchIntegrityAlarms().listen(
      (rows) {
        alarms[workspaceId] = rows;
        emit();
      },
      onError: fail,
    ));
    subscriptions.add(client.watchQuarantined().listen(
      (rows) {
        refusals[workspaceId] = rows;
        emit();
      },
      onError: fail,
    ));
  }

  // Seeded for the same reason the status stream is: the watch streams emit on
  // change, so a screen opened over a settled store would sit in `AsyncLoading`
  // for ever.
  emit();
  yield* controller.stream;
});
