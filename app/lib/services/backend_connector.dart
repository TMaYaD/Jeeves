// PowerSync BackendConnector for Jeeves.
//
// Responsibilities:
//   1. fetchCredentials() — call /powersync/credentials on the backend to
//      obtain a short-lived JWT and the PowerSync service URL.
//   2. uploadData()       — drain PowerSync's CRUD queue and persist each
//      local write to the backend via the existing REST API.

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:powersync/powersync.dart' as ps;

import 'api_service.dart';
import 'platform_helper.dart'
    if (dart.library.io) 'platform_helper_io.dart';

class JevesBackendConnector extends ps.PowerSyncBackendConnector {
  JevesBackendConnector(this._api);

  final ApiService _api;

  @override
  Future<ps.PowerSyncCredentials?> fetchCredentials() async {
    final data = await _api.get('/powersync/credentials');
    var endpoint = data['powersync_url'] as String;
    // Android emulator cannot reach the host's localhost; Google's emulator
    // routes 10.0.2.2 to host loopback.  iOS/macOS/web are unaffected.
    if (!kIsWeb && isAndroidPlatform) {
      endpoint = endpoint.replaceFirst('://localhost', '://10.0.2.2');
    }
    final token = data['token'] as String;
    // userId is optional metadata — PowerSync uses it only for logging.
    // We mine it from the JWT's `sub` claim so we don't have to widen the
    // backend response.
    return ps.PowerSyncCredentials(
      endpoint: endpoint,
      token: token,
      userId: _userIdFromJwt(token),
    );
  }

  /// Upload locally-queued writes to the backend REST API.
  ///
  /// Each CRUD entry maps to the corresponding REST endpoint:
  ///   - todos:     POST /todos/,       PATCH /todos/{id},      DELETE /todos/{id}
  ///   - tags:      POST /tags/,        PATCH /tags/{id},       DELETE /tags/{id}
  ///   - todo_tags: POST /todo_tags/,                           DELETE /todo_tags/{id}
  ///
  /// Errors are classified per-entry so one bad row doesn't poison the batch:
  ///   - 4xx (except 401) is fatal for THAT entry — log it and skip; the
  ///     rest of the batch still runs.  If data-loss protection matters,
  ///     stash the failing CRUD elsewhere for manual reconciliation first.
  ///   - 5xx, network errors, and 401 are transient — rethrow so PowerSync
  ///     retries the whole batch on the next connect/backoff.
  @override
  Future<void> uploadData(ps.PowerSyncDatabase database) async {
    final batch = await database.getCrudBatch();
    if (batch == null) return;

    for (final entry in batch.crud) {
      try {
        switch (entry.table) {
          case 'todos':
            await _uploadTodo(entry);
          case 'tags':
            await _uploadTag(entry);
          case 'todo_tags':
            await _uploadTodoTag(entry);
          default:
            debugPrint(
              'JevesBackendConnector: unhandled table ${entry.table}',
            );
        }
      } on DioException catch (e) {
        if (_isFatal(e)) {
          debugPrint(
            'JevesBackendConnector: fatal error on $entry '
            '(status ${e.response?.statusCode}); skipping entry',
          );
          // Drop only this entry — continue with the rest of the batch.
          continue;
        }
        rethrow; // Transient — let PowerSync retry the whole batch.
      }
    }
    await batch.complete();
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

  /// 4xx responses indicate a client-side problem (bad payload, stale
  /// row, RLS violation).  Retrying will keep failing, so we treat them
  /// as fatal and complete the batch to unblock the queue.
  /// 401 and 429 are deliberately *not* fatal: 401 triggers a JWT
  /// refresh on the next attempt, and 429 is back-pressure — PowerSync's
  /// retry backoff will resolve it.
  static bool _isFatal(DioException e) {
    final code = e.response?.statusCode;
    if (code == null) return false; // Network error — retry.
    if (code == 401 || code == 429) return false;
    return code >= 400 && code < 500;
  }

  /// Extract the `sub` claim from a JWT.  Returns `null` on malformed
  /// tokens; PowerSync treats a null userId as anonymous, which is
  /// acceptable for a debugging-only field.
  static String? _userIdFromJwt(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final payload = parts[1];
      final padded = payload.padRight(
        payload.length + (4 - payload.length % 4) % 4,
        '=',
      );
      final decoded = utf8.decode(base64Url.decode(padded));
      final json = jsonDecode(decoded) as Map<String, dynamic>;
      return json['sub'] as String?;
    } catch (_) {
      return null;
    }
  }
}
