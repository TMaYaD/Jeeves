import 'package:powersync/powersync.dart' as ps;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_provider.dart';
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
/// Once authenticated, maps PowerSync's connection status stream to the enum.
final syncStatusProvider = StreamProvider<SyncStatus>((ref) async* {
  final userId = ref.watch(currentUserIdProvider);

  if (userId == 'local') {
    yield SyncStatus.localOnly;
    return;
  }

  final db = await ref.read(powerSyncInstanceProvider.future);

  // Seed with the current status: [statusStream] only emits on *changes*,
  // so a subscriber that attaches after PowerSync has already reached a
  // stable state would otherwise stay in AsyncLoading forever (asData ==
  // null), leaving the UI stuck on the "local only" fallback icon.
  yield _map(db.currentStatus);
  yield* db.statusStream.map(_map);
});
