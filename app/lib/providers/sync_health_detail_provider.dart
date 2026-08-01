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
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jeeves/sync/sync_database.dart';

import '../sync/sync_health_detail.dart';
import 'auth_provider.dart';
import 'sync_lifecycle_provider.dart';
import 'sync_stack_provider.dart';
import 'user_constants.dart';

final syncHealthDetailProvider =
    StreamProvider<List<SyncHealthCondition>>((ref) async* {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == kLocalUserId) {
    yield const [];
    return;
  }

  await ref.watch(syncLifecycleProvider.future);
  final stack = await ref.watch(syncStackProvider.future);

  final controller = StreamController<List<SyncHealthCondition>>();
  final alarms = <String, List<IntegrityAlarmRow>>{};
  final refusals = <String, List<QuarantineRow>>{};

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

  final subscriptions = <StreamSubscription<void>>[];
  for (final workspaceId in stack.workspaceIds) {
    final client = await stack.workspaceClientFactory(workspaceId);
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

  ref.onDispose(() {
    for (final subscription in subscriptions) {
      subscription.cancel();
    }
    controller.close();
  });

  // Seeded for the same reason the status stream is: the watch streams emit on
  // change, so a screen opened over a settled store would sit in `AsyncLoading`
  // for ever.
  emit();
  yield* controller.stream;
});
