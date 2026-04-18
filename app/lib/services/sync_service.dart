// Sync service — PowerSync integration.
//
// Responsible for:
// - Connecting to the self-hosted PowerSync service for bidirectional sync
// - Syncing three shapes: todos, tags, todo_tags (all filtered by user_id)
// - Surfacing sync status to the UI via a [SyncStatus] stream
// - Tracking pending (unsynced) writes via PowerSync's upload queue

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart' as ps;

import '../database/powersync_schema.dart';
import 'api_service.dart';
import 'backend_connector.dart';

export 'backend_connector.dart';

enum SyncStatus { disconnected, connecting, synced, error }

class SyncService {
  SyncService._();

  static final SyncService instance = SyncService._();

  ps.PowerSyncDatabase? _db;
  StreamSubscription<SyncStatus>? _statusSub;

  final _statusController = StreamController<SyncStatus>.broadcast();

  /// Current sync status stream.
  Stream<SyncStatus> get statusStream => _statusController.stream;

  /// Stream of the actual number of locally queued (unsynced) writes.
  Stream<int> get pendingWriteCountStream {
    final db = _db;
    if (db == null) return Stream.value(0);
    return db.statusStream.asyncMap((_) async {
      final stats = await db.getUploadQueueStats();
      return stats.count;
    });
  }

  /// Connect to PowerSync and begin bidirectional sync.
  ///
  /// Call after the user has authenticated and an [ApiService] with a valid
  /// auth token is available.
  Future<void> start({required ApiService api}) async {
    if (_db != null) return; // Already started; avoid duplicate initialization.
    _statusController.add(SyncStatus.connecting);

    final dbFolder = await getApplicationDocumentsDirectory();
    final dbPath = p.join(dbFolder.path, 'jeeves.sqlite');

    _db = ps.PowerSyncDatabase(
      schema: powersyncSchema,
      path: dbPath,
    );
    await _db!.initialize();

    final connector = JevesBackendConnector(api);
    await _db!.connect(connector: connector);

    // Map PowerSync's internal SyncStatus to the app's SyncStatus enum.
    _statusSub = _db!.statusStream.map(_toAppStatus).listen(
      _statusController.add,
      onError: (_) => _statusController.add(SyncStatus.error),
    );
  }

  /// Trigger a manual sync refresh (e.g. on pull-to-refresh).
  Future<void> sync() async {
    final db = _db;
    if (db == null) {
      _statusController.add(SyncStatus.error);
      return;
    }
    _statusController.add(SyncStatus.connecting);
    // PowerSync syncs continuously when connected; emit the current status.
    _statusController.add(_toAppStatus(db.currentStatus));
  }

  /// Disconnect from PowerSync and release resources.
  Future<void> stop() async {
    await _statusSub?.cancel();
    _statusSub = null;
    await _db?.disconnect();
    _db = null;
    _statusController.add(SyncStatus.disconnected);
  }

  /// No-op: PowerSync's upload queue replaces the manual pending-write counter.
  void trackPendingWrite() {}

  /// No-op: PowerSync's upload queue replaces the manual pending-write counter.
  void acknowledgePendingWrite() {}

  void dispose() {
    _statusController.close();
  }

  static SyncStatus _toAppStatus(ps.SyncStatus status) {
    if (status.anyError != null) return SyncStatus.error;
    if (status.connecting || status.downloading || status.uploading) {
      return SyncStatus.connecting;
    }
    if (status.connected && status.hasSynced == true) {
      return SyncStatus.synced;
    }
    if (status.lastSyncedAt != null) return SyncStatus.disconnected;
    return SyncStatus.connecting;
  }
}

final syncServiceProvider = Provider<SyncService>((ref) {
  return SyncService.instance;
});
