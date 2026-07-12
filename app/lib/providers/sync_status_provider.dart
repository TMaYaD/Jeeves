import 'dart:async';

import 'package:powersync/powersync.dart' as ps;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_provider.dart';
import 'database_provider.dart';
import 'powersync_provider.dart';

enum SyncStatus { localOnly, connecting, syncing, synced, error }

SyncStatus _map(ps.SyncStatus status) {
  if (status.anyError != null) return SyncStatus.error;
  if (status.downloading || status.uploading) return SyncStatus.syncing;
  if (status.connecting) return SyncStatus.connecting;
  return SyncStatus.synced;
}

/// Stream of the current sync status.
///
/// Returns [SyncStatus.localOnly] immediately when the user is unauthenticated.
/// Once authenticated, combines PowerSync's connection status stream with the
/// dead-letter count from `sync_dead_letters`: any recorded non-retryable
/// upload failure (see `JevesBackendConnector.classifyUploadError`) forces
/// [SyncStatus.error] so the drawer's sync indicator surfaces it — even while
/// the engine itself reports a healthy connection.
final syncStatusProvider = StreamProvider<SyncStatus>((ref) async* {
  final userId = ref.watch(currentUserIdProvider);

  if (userId == 'local') {
    yield SyncStatus.localOnly;
    return;
  }

  final psDb = await ref.read(powerSyncInstanceProvider.future);
  final db = ref.read(databaseProvider);

  // Hand-rolled combine-latest over the two inputs.  Seeded with the current
  // engine status: [statusStream] only emits on *changes*, so a subscriber
  // that attaches after PowerSync has already reached a stable state would
  // otherwise stay in AsyncLoading forever (asData == null), leaving the UI
  // stuck on the "local only" fallback icon.  The dead-letter count starts at
  // zero and corrects itself when the watch query's first row arrives.
  final controller = StreamController<SyncStatus>();
  var engine = _map(psDb.currentStatus);
  var deadLetters = 0;
  SyncStatus? lastEmitted;

  void emit() {
    if (controller.isClosed) return;
    final next = deadLetters > 0 ? SyncStatus.error : engine;
    if (next == lastEmitted) return; // Both inputs re-fire independently.
    lastEmitted = next;
    controller.add(next);
  }

  void forwardError(Object error, StackTrace stackTrace) {
    if (controller.isClosed) return;
    controller.addError(error, stackTrace);
  }

  final engineSub = psDb.statusStream.listen(
    (status) {
      engine = _map(status);
      emit();
    },
    onError: forwardError,
  );
  final deadLetterSub = db.watchSyncDeadLetterCount().listen(
    (count) {
      deadLetters = count;
      emit();
    },
    onError: forwardError,
  );
  ref.onDispose(() {
    engineSub.cancel();
    deadLetterSub.cancel();
    controller.close();
  });

  emit();
  yield* controller.stream;
});
