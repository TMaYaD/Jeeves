// Sync service — PowerSync integration.
//
// Responsible for:
// - Connecting to the self-hosted PowerSync service for bidirectional sync
// - Syncing three shapes: todos, tags, todo_tags (all filtered by user_id)
// - Surfacing sync status to the UI via a [SyncStatus] stream
// - Tracking pending (unsynced) writes via PowerSync's upload queue
// - Preserving any data written by pre-PowerSync builds of the app:
//   legacy Drift-managed tables sharing the same `jeeves.sqlite` file are
//   renamed before PowerSync initializes (so its views can be created) and
//   their rows are copied into the view-backed schema afterwards, seeding
//   the upload queue so prior work replicates to the server on first sync.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart' as ps;
import 'package:sqlite_async/sqlite_async.dart' as sa;

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
  StreamSubscription<ps.SyncStatus>? _pendingWriteSub;

  final _statusController = StreamController<SyncStatus>.broadcast();
  final _pendingWriteCountController = StreamController<int>.broadcast();

  /// Completes when [start] has initialized the PowerSync database.
  /// Recreated on every [stop] so a re-login hands out a fresh future.
  Completer<ps.PowerSyncDatabase> _readyCompleter =
      Completer<ps.PowerSyncDatabase>();

  /// The PowerSync database, resolving once [start] has finished initializing.
  ///
  /// Used by the Drift `databaseProvider` via [DatabaseConnection.delayed] so
  /// any query issued before login is queued and flushed on connection.
  Future<ps.PowerSyncDatabase> get whenReady => _readyCompleter.future;

  /// Current sync status stream.
  Stream<SyncStatus> get statusStream => _statusController.stream;

  /// Stream of the actual number of locally queued (unsynced) writes.
  /// Long-lived — subscribers survive stop/restart cycles.
  Stream<int> get pendingWriteCountStream => _pendingWriteCountController.stream;

  Future<void> _emitPendingWriteCount() async {
    final db = _db;
    if (db == null) {
      _pendingWriteCountController.add(0);
      return;
    }
    final stats = await db.getUploadQueueStats();
    _pendingWriteCountController.add(stats.count);
  }

  /// Connect to PowerSync and begin bidirectional sync.
  ///
  /// Call after the user has authenticated and an [ApiService] with a valid
  /// auth token is available.  [currentUserId] is the authenticated user's
  /// id — used by the one-shot legacy-data migration (see
  /// [_importLegacyData]) to re-attribute rows that were written by a
  /// pre-auth build of the app (which used `'local'` as a placeholder).
  Future<void> start({
    required ApiService api,
    required String currentUserId,
  }) async {
    if (_db != null) return; // Already started; avoid duplicate initialization.
    _statusController.add(SyncStatus.connecting);

    final dbFolder = await getApplicationDocumentsDirectory();
    final dbPath = p.join(dbFolder.path, 'jeeves.sqlite');

    // Pre-init migration: a prior build of this app wrote Drift-managed
    // tables (todos, tags, todo_tags) directly into `jeeves.sqlite`.
    // PowerSync creates *views* with those exact names during init and
    // would otherwise collide with the existing tables.  Rename them out
    // of the way here; the data is reattached below in [_importLegacyData].
    await _renameLegacyTablesIfPresent(dbPath);

    _db = ps.PowerSyncDatabase(
      schema: powersyncSchema,
      path: dbPath,
    );
    await _db!.initialize();

    // Post-init migration: copy rows from the renamed legacy tables into
    // the PowerSync-managed views.  Every INSERT queues an upload-queue
    // entry, so the user's prior work replicates to the server on first
    // sync.  The DROP of the `_legacy_*` tables happens inside the same
    // transaction as the copy, so a mid-migration crash rolls everything
    // back and the next start retries cleanly.
    await _importLegacyData(_db!, currentUserId);

    // Hand the initialized database to any consumer awaiting [whenReady] —
    // notably the Drift `databaseProvider`, which wraps this in a
    // DatabaseConnection.delayed.
    if (!_readyCompleter.isCompleted) {
      _readyCompleter.complete(_db!);
    }

    final connector = JevesBackendConnector(api);
    await _db!.connect(connector: connector);

    // Map PowerSync's internal SyncStatus to the app's SyncStatus enum and
    // refresh the pending write count on every status change.
    _statusSub = _db!.statusStream.map(_toAppStatus).listen(
      _statusController.add,
      onError: (_) => _statusController.add(SyncStatus.error),
    );
    _pendingWriteSub = _db!.statusStream.listen(
      (_) => _emitPendingWriteCount(),
    );
    await _emitPendingWriteCount();
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
    await _pendingWriteSub?.cancel();
    _pendingWriteSub = null;
    await _db?.disconnect();
    _db = null;
    // Next [start] (e.g. after re-login) must hand out a fresh ready future.
    _readyCompleter = Completer<ps.PowerSyncDatabase>();
    _statusController.add(SyncStatus.disconnected);
    _pendingWriteCountController.add(0);
  }

  /// No-op: PowerSync's upload queue replaces the manual pending-write counter.
  void trackPendingWrite() {}

  /// No-op: PowerSync's upload queue replaces the manual pending-write counter.
  void acknowledgePendingWrite() {}

  Future<void> dispose() async {
    await stop();
    await _statusController.close();
    await _pendingWriteCountController.close();
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

  // ---------------------------------------------------------------------------
  // Legacy data migration
  //
  // Older builds of Jeeves stored todos/tags/todo_tags as regular Drift
  // tables inside `jeeves.sqlite`.  PowerSync now owns that file and
  // exposes those same names as views over its internal storage, so the
  // file cannot host both shapes simultaneously.  The two helpers below
  // perform a one-shot, atomic handover:
  //
  //   1. [_renameLegacyTablesIfPresent] runs before PowerSync initializes,
  //      renaming any real `todos` / `tags` / `todo_tags` tables to
  //      `_legacy_*` so PowerSync's view creation succeeds.
  //   2. [_importLegacyData] runs after initialization, reading each
  //      `_legacy_*` table, rewriting Drift-era column encodings to the
  //      shapes PowerSync expects (epoch-seconds INTEGER → ISO-8601 TEXT
  //      for timestamps; `'local'` placeholder → real user id), and
  //      INSERTing into the view.  The DROPs of the legacy tables happen
  //      inside the same write transaction as the INSERTs — a crash
  //      mid-migration rolls everything back so the next start retries
  //      cleanly with no duplicate rows.
  //
  // Views of type `'view'` in sqlite_master are skipped by the rename step
  // (the filter is `type='table'`), so subsequent starts after a
  // successful migration are effectively no-ops.
  // ---------------------------------------------------------------------------

  Future<void> _renameLegacyTablesIfPresent(String dbPath) async {
    final raw = sa.SqliteDatabase(path: dbPath);
    try {
      await raw.initialize();
      final rows = await raw.getAll(
        "SELECT name FROM sqlite_master "
        "WHERE type = 'table' AND name IN ('todos', 'tags', 'todo_tags')",
      );
      if (rows.isEmpty) return;
      final existing = rows.map((r) => r['name'] as String).toSet();
      await raw.writeTransaction((tx) async {
        for (final name in existing) {
          // Drop any stale _legacy_<name> from a previous aborted run so
          // the rename is idempotent.
          await tx.execute('DROP TABLE IF EXISTS _legacy_$name');
          await tx.execute('ALTER TABLE $name RENAME TO _legacy_$name');
        }
      });
    } finally {
      await raw.close();
    }
  }

  Future<void> _importLegacyData(
    ps.PowerSyncDatabase db,
    String currentUserId,
  ) async {
    final tables = await db.getAll(
      "SELECT name FROM sqlite_master "
      "WHERE type = 'table' AND name IN ('_legacy_todos', '_legacy_tags', "
      "'_legacy_todo_tags')",
    );
    if (tables.isEmpty) return;
    final names = tables.map((r) => r['name'] as String).toSet();

    // Copy tags first, then todos, then todo_tags (the junction).  Even
    // though the view schema has no FK constraints, this ordering keeps
    // the on-disk history in a sensible causal order.
    await db.writeTransaction((tx) async {
      if (names.contains('_legacy_tags')) {
        await _copyLegacyTags(tx, currentUserId);
      }
      if (names.contains('_legacy_todos')) {
        await _copyLegacyTodos(tx, currentUserId);
      }
      if (names.contains('_legacy_todo_tags')) {
        await _copyLegacyTodoTags(tx);
      }
      for (final name in names) {
        await tx.execute('DROP TABLE $name');
      }
    });
  }

  Future<void> _copyLegacyTags(
    sa.SqliteWriteContext tx,
    String currentUserId,
  ) async {
    final rows = await tx.getAll('SELECT * FROM _legacy_tags');
    for (final row in rows) {
      await tx.execute(
        'INSERT INTO tags (id, name, color, type, user_id) '
        'VALUES (?, ?, ?, ?, ?)',
        [
          row['id'],
          row['name'],
          row['color'],
          row['type'],
          _remapUserId(row['user_id'], currentUserId),
        ],
      );
    }
  }

  Future<void> _copyLegacyTodos(
    sa.SqliteWriteContext tx,
    String currentUserId,
  ) async {
    final rows = await tx.getAll('SELECT * FROM _legacy_todos');
    final columns = rows.isEmpty ? const <String>{} : rows.first.keys.toSet();
    for (final row in rows) {
      await tx.execute(
        '''
        INSERT INTO todos (
          id, title, notes, completed, priority, due_date, created_at,
          updated_at, state, time_estimate, energy_level, capture_source,
          location_id, user_id, waiting_for, in_progress_since,
          time_spent_minutes, blocked_by_todo_id, selected_for_today,
          daily_selection_date
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          row['id'],
          row['title'],
          row['notes'],
          row['completed'],
          row['priority'],
          _epochSecondsToIso(row['due_date']),
          _epochSecondsToIso(row['created_at']),
          _epochSecondsToIso(row['updated_at']),
          row['state'],
          row['time_estimate'],
          row['energy_level'],
          row['capture_source'],
          row['location_id'],
          _remapUserId(row['user_id'], currentUserId),
          // `waiting_for` only exists on schemas shipped with this build;
          // older Drift files don't have the column.
          columns.contains('waiting_for') ? row['waiting_for'] : null,
          row['in_progress_since'],
          row['time_spent_minutes'] ?? 0,
          row['blocked_by_todo_id'],
          row['selected_for_today'],
          row['daily_selection_date'],
        ],
      );
    }
  }

  Future<void> _copyLegacyTodoTags(sa.SqliteWriteContext tx) async {
    final rows = await tx.getAll(
      'SELECT todo_id, tag_id FROM _legacy_todo_tags',
    );
    for (final row in rows) {
      // PowerSync manages an implicit `id` column for every view; the
      // junction table has no natural single-column key, so mint a fresh
      // UUID here.  PowerSync exposes a `uuid()` SQL function on the
      // embedded SQLite build for exactly this case.
      await tx.execute(
        'INSERT INTO todo_tags (id, todo_id, tag_id) VALUES (uuid(), ?, ?)',
        [row['todo_id'], row['tag_id']],
      );
    }
  }

  static String _remapUserId(Object? legacyUserId, String currentUserId) {
    // Pre-auth builds stamped every local row with `'local'` because there
    // was no authenticated user yet.  Rewrite those to the real id so the
    // upload queue sends them for the correct server-side user.  Any
    // other value is a real id and is preserved verbatim.
    if (legacyUserId is! String || legacyUserId.isEmpty || legacyUserId == 'local') {
      return currentUserId;
    }
    return legacyUserId;
  }

  static String? _epochSecondsToIso(Object? value) {
    // Drift's default DateTimeColumn encoding (before
    // `store_date_time_values_as_text: true`) is INTEGER seconds since
    // the Unix epoch.  PowerSync persists timestamps as ISO-8601 TEXT,
    // so legacy numeric values must be rewritten on the way across.
    if (value == null) return null;
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true)
          .toIso8601String();
    }
    if (value is String) return value; // Already ISO-8601.
    return null;
  }
}

final syncServiceProvider = Provider<SyncService>((ref) {
  return SyncService.instance;
});
