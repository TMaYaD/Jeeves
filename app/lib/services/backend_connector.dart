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
  ///   - todos: POST /todos/, PATCH /todos/{id}, DELETE /todos/{id}
  ///   - tags/todo_tags: managed server-side via todo operations; skip here.
  @override
  Future<void> uploadData(ps.PowerSyncDatabase database) async {
    final batch = await database.getCrudBatch();
    if (batch == null) return;

    try {
      for (final ps.CrudEntry entry in batch.crud) {
        switch (entry.table) {
          case 'todos':
            await _uploadTodo(entry);
          default:
            // tags and todo_tags are managed server-side when todos are
            // created/updated. No direct upload needed for these tables.
            break;
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
        await _api.post('/todos/', entry.opData ?? {});
      case ps.UpdateType.patch:
        await _api.patch('/todos/${entry.id}', entry.opData ?? {});
      case ps.UpdateType.delete:
        await _api.delete('/todos/${entry.id}');
    }
  }
}
