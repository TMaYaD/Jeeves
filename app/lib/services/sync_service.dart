// Sync service — Electric SQL client integration.
//
// Responsible for:
// - Maintaining the local Drift database as the offline-first store
// - Syncing changes from/to the Electric SQL replication layer via three shapes:
//     1. todos   (filtered by user_id)
//     2. tags    (filtered by user_id)
//     3. todo_tags (references user-scoped todo_id rows)
// - Surfacing sync status to UI via a [SyncStatus] stream
// - Tracking pending (unsynced) writes so the UI can display an indicator
//
// TODO: Replace the stub Electric client calls below with the real
// `electric_client` Flutter package once it is published.
// See: https://electric-sql.com/docs/integrations/flutter

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

enum SyncStatus { disconnected, connecting, synced, error }


class SyncService {
  SyncService._();

  static final SyncService instance = SyncService._();

  final _statusController = StreamController<SyncStatus>.broadcast();
  final _pendingWriteController = StreamController<int>.broadcast();

  int _pendingWrites = 0;

  /// Current sync status stream.
  Stream<SyncStatus> get statusStream => _statusController.stream;

  /// Stream of pending (unsynced) write counts.
  Stream<int> get pendingWriteCountStream => _pendingWriteController.stream;

  /// Start syncing.  Call after the user has authenticated and a JWT is
  /// available.  Declares the three GTD sync shapes and transitions status
  /// through [SyncStatus.connecting] → [SyncStatus.synced].
  Future<void> start({
    required String electricUrl,
    required String userId,
    required String jwt,
  }) async {
    _statusController.add(SyncStatus.connecting);

    // TODO: replace with real Electric SQL client once published:
    //
    // final client = await ElectricClient.connect(
    //   electricUrl,
    //   config: ElectricConfig(auth: AuthState(token: jwt)),
    // );
    //
    // for (final shape in _shapes) {
    //   final resolvedWhere = shape.where?.replaceAll('\$userId', userId);
    //   await client.syncShape(
    //     Shape(table: shape.table, where: resolvedWhere),
    //   );
    // }
    //
    // client.onStatusChange((status) {
    //   _statusController.add(status == ElectricStatus.connected
    //       ? SyncStatus.synced
    //       : SyncStatus.error);
    // });

    // Stub: immediately signal synced for now.
    _statusController.add(SyncStatus.synced);
  }

  /// Increment the pending write count (call before a local Drift write).
  void trackPendingWrite() {
    _pendingWrites++;
    _pendingWriteController.add(_pendingWrites);
  }

  /// Decrement the pending write count (call after Electric confirms the write).
  void acknowledgePendingWrite() {
    if (_pendingWrites > 0) {
      _pendingWrites--;
      _pendingWriteController.add(_pendingWrites);
    }
  }

  /// Trigger a one-shot sync attempt.  Emits status transitions so the UI
  /// receives an explicit non-success result until Electric SQL is wired.
  Future<void> sync() async {
    _statusController.add(SyncStatus.connecting);
    // TODO: trigger Electric SQL sync when client is available
    _statusController.add(SyncStatus.error);
  }

  Future<void> stop() async {
    // TODO: disconnect Electric SQL client
    _statusController.add(SyncStatus.disconnected);
  }

  void dispose() {
    _statusController.close();
    _pendingWriteController.close();
  }
}

final syncServiceProvider = Provider<SyncService>((ref) {
  return SyncService.instance;
});
