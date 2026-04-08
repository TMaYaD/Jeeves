/// Sync service — Electric SQL client integration.
///
/// Responsible for:
/// - Maintaining the local Drift database as the offline-first store
/// - Syncing changes from/to the Electric SQL replication layer
/// - Surfacing sync status to UI via a [SyncStatus] stream
///
/// TODO: Wire up the Electric SQL Flutter client once the package is published.
/// For now this is a placeholder that signals "not synced".

import 'package:flutter_riverpod/flutter_riverpod.dart';

enum SyncStatus { disconnected, connecting, synced, error }

class SyncService {
  SyncService._();

  static final SyncService instance = SyncService._();

  final _statusController = Stream<SyncStatus>.value(SyncStatus.disconnected);

  Stream<SyncStatus> get statusStream => _statusController;

  Future<void> start({required String electricUrl}) async {
    // TODO: initialize Electric SQL client
    // electricClient = await ElectricClient.connect(electricUrl);
    // electricClient.sync(shape: Shape(table: 'todos'));
  }

  Future<void> stop() async {
    // TODO: disconnect Electric SQL client
  }
}

final syncServiceProvider = Provider<SyncService>((ref) {
  return SyncService.instance;
});
