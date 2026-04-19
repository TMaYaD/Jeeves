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
  /// Errors are classified to avoid wedging the upload queue:
  ///   - 4xx responses are fatal (malformed payload, RLS violation,
  ///     row-not-found on PATCH/DELETE etc.).  The offending entry is
  ///     logged and the whole batch is marked complete so subsequent
  ///     writes aren't blocked behind it.  If data-loss protection ever
  ///     matters, escalate here — stash the failing CRUD elsewhere for
  ///     manual reconciliation before completing.
  ///   - 5xx and network errors are transient — rethrow so PowerSync
  ///     retries the batch on the next connect/backoff.
  @override
  Future<void> uploadData(ps.PowerSyncDatabase database) async {
    final batch = await database.getCrudBatch();
    if (batch == null) return;

    ps.CrudEntry? lastEntry;
    try {
      for (final entry in batch.crud) {
        lastEntry = entry;
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
      }
      await batch.complete();
    } on DioException catch (e) {
      if (_isFatal(e)) {
        debugPrint(
          'JevesBackendConnector: fatal error on $lastEntry '
          '(status ${e.response?.statusCode}); discarding batch',
        );
        await batch.complete();
      } else {
        rethrow; // Transient — let PowerSync retry.
      }
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

  /// 4xx responses indicate a client-side problem (bad payload, stale
  /// row, RLS violation).  Retrying will keep failing, so we treat them
  /// as fatal and complete the batch to unblock the queue.
  /// 401 is deliberately *not* fatal — the auth layer will refresh the
  /// JWT and the batch will succeed on retry.
  static bool _isFatal(DioException e) {
    final code = e.response?.statusCode;
    if (code == null) return false; // Network error — retry.
    if (code == 401) return false; // Token refresh path — retry.
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
