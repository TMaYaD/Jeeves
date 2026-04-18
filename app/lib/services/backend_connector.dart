// PowerSync BackendConnector for Jeeves.
//
// Responsibilities:
//   1. fetchCredentials() — call /powersync/credentials on the backend to
//      obtain a short-lived JWT and the PowerSync service URL.
//   2. uploadData()       — drain PowerSync's CRUD queue and persist each
//      local write to the backend via the existing REST API.

import 'package:powersync/powersync.dart' as ps;

import 'api_service.dart';

class JevesBackendConnector extends ps.PowerSyncBackendConnector {
  JevesBackendConnector(this._api);

  final ApiService _api;

  @override
  Future<ps.PowerSyncCredentials?> fetchCredentials() async {
    final data = await _api.get('/powersync/credentials');
    return ps.PowerSyncCredentials(
      endpoint: data['powersync_url'] as String,
      token: data['token'] as String,
    );
  }

  /// Upload locally-queued writes to the backend REST API.
  ///
  /// Each CRUD entry maps to the corresponding REST endpoint:
  ///   - todos:     POST /todos/,       PATCH /todos/{id},      DELETE /todos/{id}
  ///   - tags:      POST /tags/,        PATCH /tags/{id},       DELETE /tags/{id}
  ///   - todo_tags: POST /todo_tags/,                           DELETE /todo_tags/{id}
  @override
  Future<void> uploadData(ps.PowerSyncDatabase database) async {
    final batch = await database.getCrudBatch();
    if (batch == null) return;

    try {
      for (final ps.CrudEntry entry in batch.crud) {
        switch (entry.table) {
          case 'todos':
            await _uploadTodo(entry);
          case 'tags':
            await _uploadTag(entry);
          case 'todo_tags':
            await _uploadTodoTag(entry);
          default:
            // ignore: avoid_print
            print('Warning: unhandled table in CRUD batch: ${entry.table}');
        }
      }
      await batch.complete();
    } catch (e) {
      // Leave the batch incomplete so PowerSync retries on next connect.
      rethrow;
    }
  }

  Future<void> _uploadTodo(ps.CrudEntry entry) async {
    switch (entry.op) {
      case ps.UpdateType.put:
        // Include entry.id so the backend can deduplicate on retry.
        final body = Map<String, dynamic>.from(entry.opData ?? {});
        body['id'] = entry.id;
        await _api.post('/todos/', body);
      case ps.UpdateType.patch:
        await _api.patch('/todos/${entry.id}', entry.opData ?? {});
      case ps.UpdateType.delete:
        await _api.delete('/todos/${entry.id}');
    }
  }

  Future<void> _uploadTag(ps.CrudEntry entry) async {
    switch (entry.op) {
      case ps.UpdateType.put:
        final body = Map<String, dynamic>.from(entry.opData ?? {});
        body['id'] = entry.id;
        await _api.post('/tags/', body);
      case ps.UpdateType.patch:
        await _api.patch('/tags/${entry.id}', entry.opData ?? {});
      case ps.UpdateType.delete:
        await _api.delete('/tags/${entry.id}');
    }
  }

  Future<void> _uploadTodoTag(ps.CrudEntry entry) async {
    switch (entry.op) {
      case ps.UpdateType.put:
        final body = Map<String, dynamic>.from(entry.opData ?? {});
        body['id'] = entry.id;
        await _api.post('/todo_tags/', body);
      case ps.UpdateType.patch:
        // todo_tags has no updatable fields; treat as no-op.
        break;
      case ps.UpdateType.delete:
        await _api.delete('/todo_tags/${entry.id}');
    }
  }
}
