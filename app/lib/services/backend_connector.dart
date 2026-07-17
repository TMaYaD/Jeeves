// PowerSync BackendConnector for Jeeves.
//
// Responsibilities:
//   1. fetchCredentials() — call /powersync/credentials on the backend to
//      obtain a short-lived JWT and the PowerSync service URL.
//   2. uploadData()       — drain PowerSync's CRUD queue and persist each
//      local write to the backend via the existing REST API, applying the
//      per-status upload-error policy (see [classifyUploadError] and
//      docs/ARCHITECTURE.md § Sync Engine).

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart'
    show debugPrint, kIsWeb, visibleForTesting;
import 'package:powersync/powersync.dart' as ps;

import '../database/gtd_database.dart';
import 'api_service.dart';
import 'platform_helper.dart'
    if (dart.library.io) 'platform_helper_io.dart';

/// What the connector does with a CRUD entry whose upload failed.
///
/// PowerSync queue mechanics force a three-way choice: rethrowing keeps the
/// entry queued but blocks every later upload behind it (head-of-line), so
/// only genuinely transient errors may [retry]; everything else must leave
/// the queue — either [discard]ed because the server outcome already matches
/// the client's intent, or [deadLetter]ed so the failure is recorded and
/// surfaced instead of silently lost.
enum UploadErrorAction {
  /// Transient — rethrow so PowerSync retries the batch on the next backoff.
  retry,

  /// The remote row is already gone; server deletion wins and the next pull
  /// converges local state. Logged, not recorded.
  discard,

  /// Non-retryable — record a `sync_dead_letters` row (payload + response
  /// body) and continue, so the failure is diagnosable and never silent.
  deadLetter,
}

class JevesBackendConnector extends ps.PowerSyncBackendConnector {
  JevesBackendConnector(this._api, this._db);

  final ApiService _api;
  final GtdDatabase _db;

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

  @override
  Future<void> uploadData(ps.PowerSyncDatabase database) async {
    final batch = await database.getCrudBatch();
    if (batch == null) return;
    await uploadCrudBatch(batch);
  }

  /// Upload every locally-queued write in [batch] to the backend REST API.
  ///
  /// Each CRUD entry maps to the corresponding REST endpoint:
  ///   - todos:               POST /todos/,               PATCH /todos/{id},               DELETE /todos/{id}
  ///   - tags:                POST /tags/,                PATCH /tags/{id},                DELETE /tags/{id}
  ///   - todo_tags:           POST /todo_tags/,                                            DELETE /todo_tags/{id}
  ///   - user_preferences:    POST /user_preferences/,    PATCH /user_preferences/{id},    DELETE /user_preferences/{id}
  ///   - focus_sessions:      POST /focus_sessions/,      PATCH /focus_sessions/{id},      DELETE /focus_sessions/{id}
  ///   - focus_session_tasks: POST /focus_session_tasks/, PATCH /focus_session_tasks/{id}, DELETE /focus_session_tasks/{id}
  ///   - focus_session_dispositions: POST /focus_session_dispositions/, PATCH /focus_session_dispositions/{id}, DELETE /focus_session_dispositions/{id}
  ///   - time_logs:           POST /time_logs/,           PATCH /time_logs/{id},           DELETE /time_logs/{id}
  ///   - captures:            POST /captures/,            PATCH /captures/{id},            DELETE /captures/{id}
  ///   - capture_outcomes:    POST /capture_outcomes/,    PATCH /capture_outcomes/{id},    DELETE /capture_outcomes/{id}
  ///   - capture_tags:        POST /capture_tags/,                                         DELETE /capture_tags/{id}  (no mutable fields)
  ///
  /// Unknown tables must throw — otherwise `batch.complete()` would clear
  /// the local CRUD queue without ever talking to the server, silently
  /// losing the user's offline writes.
  ///
  /// Errors are classified per-entry by [classifyUploadError] so one bad row
  /// doesn't poison the batch: transient errors rethrow (PowerSync retries
  /// the whole batch on the next connect/backoff), a 404 on patch/delete is
  /// discarded (the remote row is already gone), and every other 4xx is
  /// dead-lettered — recorded in `sync_dead_letters` with its payload and
  /// response body, surfaced via the sync-status indicator, never silently
  /// dropped.
  @visibleForTesting
  Future<void> uploadCrudBatch(ps.CrudBatch batch) async {
    for (final entry in batch.crud) {
      try {
        switch (entry.table) {
          case 'todos':
            await _uploadTodo(entry);
          case 'tags':
            await _uploadTag(entry);
          case 'todo_tags':
            await _uploadTodoTag(entry);
          case 'user_preferences':
            await _uploadUserPreference(entry);
          case 'focus_sessions':
            await _uploadFocusSession(entry);
          case 'focus_session_tasks':
            await _uploadFocusSessionTask(entry);
          case 'focus_session_dispositions':
            await _uploadFocusSessionDisposition(entry);
          case 'time_logs':
            await _uploadTimeLog(entry);
          case 'captures':
            await _uploadCapture(entry);
          case 'capture_outcomes':
            await _uploadCaptureOutcome(entry);
          case 'capture_tags':
            await _uploadCaptureTag(entry);
          default:
            throw StateError(
              'JevesBackendConnector: no upload handler for table '
              '"${entry.table}". Add a case to uploadCrudBatch() or rows on '
              'this table will be silently lost from the CRUD queue.',
            );
        }
      } on DioException catch (e) {
        switch (classifyUploadError(entry, e)) {
          case UploadErrorAction.retry:
            rethrow; // Transient — let PowerSync retry the whole batch.
          case UploadErrorAction.discard:
            // Safe metadata only: CrudEntry.toString() interpolates the full
            // opData payload, and debugPrint emits in profile/release builds.
            debugPrint(
              'JevesBackendConnector: discarding ${entry.table}/${entry.id} '
              '${entry.op.toJson()} (status ${e.response?.statusCode}) — the '
              'remote row is already gone; the next pull converges local '
              'state',
            );
            continue;
          case UploadErrorAction.deadLetter:
            await _recordDeadLetter(entry, e);
            continue; // The rest of the batch still runs.
        }
      }
    }
    await batch.complete();
  }

  /// Maximum characters of an error response body persisted with a dead
  /// letter, so one oversized error page cannot bloat the local database.
  // not configurable: internal diagnostic truncation guard.
  static const int deadLetterResponseBodyMaxChars = 4096;

  /// Persist a non-retryable upload failure as a `sync_dead_letters` row —
  /// developer telemetry (operation × table × status + payload + response
  /// body) for fixing the root cause, not a user-facing retry queue.
  Future<void> _recordDeadLetter(ps.CrudEntry entry, DioException e) async {
    final status = e.response?.statusCode;
    final body = _encodeResponseBody(e.response?.data);
    // Safe metadata only: CrudEntry.toString() interpolates the full opData
    // payload, response bodies can echo it back (e.g. Pydantic 422 details),
    // and debugPrint emits in profile/release builds. Payload and body are
    // persisted in sync_dead_letters instead — that row is the diagnostic log.
    debugPrint(
      'JevesBackendConnector: dead-lettering ${entry.table}/${entry.id} '
      '${entry.op.toJson()} (status $status); payload and response body '
      'recorded in sync_dead_letters',
    );
    // Dead-lettering a user_preferences write still leaves the #306 read-side
    // wipe window: the payload is preserved and the failure surfaced, but the
    // next pull can remove the local row. Fail loudly in debug so a systematic
    // 4xx on this table surfaces during development; release builds record and
    // continue so one poisoned row can't block the whole queue. Keep the
    // backend routes idempotent / permissive (see docs/SYNC.md) so a
    // legitimate write never 4xx here.
    assert(
      !isSilentDataLossDrop(entry),
      'JevesBackendConnector: dead-lettered a user_preferences upload '
      '(status $status) for $entry — risks the #306 read-side wipe. Make the '
      'backend route accept this write instead of returning 4xx.',
    );
    await _db.recordSyncDeadLetter(
      tableName: entry.table,
      op: entry.op.toJson(),
      rowId: entry.id,
      opData: entry.opData == null ? null : jsonEncode(entry.opData),
      // classifyUploadError only dead-letters responses with a status code.
      statusCode: status ?? 0,
      responseBody: body,
    );
  }

  /// JSON-encode and truncate an error response body for dead-letter storage.
  static String? _encodeResponseBody(Object? data) {
    if (data == null) return null;
    String encoded;
    if (data is String) {
      encoded = data;
    } else {
      try {
        encoded = jsonEncode(data);
      } catch (_) {
        encoded = data.toString();
      }
    }
    if (encoded.isEmpty) return null;
    return encoded.length <= deadLetterResponseBodyMaxChars
        ? encoded
        : encoded.substring(0, deadLetterResponseBodyMaxChars);
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

  Future<void> _uploadUserPreference(ps.CrudEntry entry) async {
    switch (entry.op) {
      case ps.UpdateType.put:
        final body = Map<String, dynamic>.from(entry.opData ?? {});
        body['id'] = entry.id;
        await _api.post('/user_preferences/', body);
      case ps.UpdateType.patch:
        await _api.patch('/user_preferences/${entry.id}', entry.opData ?? {});
      case ps.UpdateType.delete:
        await _api.delete('/user_preferences/${entry.id}');
    }
  }

  Future<void> _uploadFocusSession(ps.CrudEntry entry) async {
    switch (entry.op) {
      case ps.UpdateType.put:
        final body = Map<String, dynamic>.from(entry.opData ?? {});
        body['id'] = entry.id;
        await _api.post('/focus_sessions/', body);
      case ps.UpdateType.patch:
        await _api.patch('/focus_sessions/${entry.id}', entry.opData ?? {});
      case ps.UpdateType.delete:
        await _api.delete('/focus_sessions/${entry.id}');
    }
  }

  Future<void> _uploadFocusSessionTask(ps.CrudEntry entry) async {
    switch (entry.op) {
      case ps.UpdateType.put:
        final body = Map<String, dynamic>.from(entry.opData ?? {});
        body['id'] = entry.id;
        await _api.post('/focus_session_tasks/', body);
      case ps.UpdateType.patch:
        // Unlike todo_tags, this junction has mutable fields (position,
        // disposition — the review flow PATCHes disposition).
        await _api.patch('/focus_session_tasks/${entry.id}', entry.opData ?? {});
      case ps.UpdateType.delete:
        await _api.delete('/focus_session_tasks/${entry.id}');
    }
  }

  Future<void> _uploadFocusSessionDisposition(ps.CrudEntry entry) async {
    switch (entry.op) {
      case ps.UpdateType.put:
        final body = Map<String, dynamic>.from(entry.opData ?? {});
        body['id'] = entry.id;
        await _api.post('/focus_session_dispositions/', body);
      case ps.UpdateType.patch:
        // The off-Plan disposition store's only mutable field is disposition.
        // The review flow re-records it via INSERT OR REPLACE (a PUT, handled
        // above and upserted server-side); this PATCH branch covers any direct
        // field update and converges the same way.
        await _api.patch(
            '/focus_session_dispositions/${entry.id}', entry.opData ?? {});
      case ps.UpdateType.delete:
        await _api.delete('/focus_session_dispositions/${entry.id}');
    }
  }

  Future<void> _uploadTimeLog(ps.CrudEntry entry) async {
    switch (entry.op) {
      case ps.UpdateType.put:
        final body = Map<String, dynamic>.from(entry.opData ?? {});
        body['id'] = entry.id;
        await _api.post('/time_logs/', body);
      case ps.UpdateType.patch:
        await _api.patch('/time_logs/${entry.id}', entry.opData ?? {});
      case ps.UpdateType.delete:
        await _api.delete('/time_logs/${entry.id}');
    }
  }

  Future<void> _uploadCapture(ps.CrudEntry entry) async {
    switch (entry.op) {
      case ps.UpdateType.put:
        final body = Map<String, dynamic>.from(entry.opData ?? {});
        body['id'] = entry.id;
        await _api.post('/captures/', body);
      case ps.UpdateType.patch:
        await _api.patch('/captures/${entry.id}', entry.opData ?? {});
      case ps.UpdateType.delete:
        await _api.delete('/captures/${entry.id}');
    }
  }

  Future<void> _uploadCaptureOutcome(ps.CrudEntry entry) async {
    switch (entry.op) {
      case ps.UpdateType.put:
        final body = Map<String, dynamic>.from(entry.opData ?? {});
        body['id'] = entry.id;
        await _api.post('/capture_outcomes/', body);
      case ps.UpdateType.patch:
        // Unlike todo_tags, this junction carries a client-owned column
        // (created_at), so a PATCH must reach the backend rather than be
        // dropped — a silently-dropped field reverts on the next checkpoint
        // download (docs/SYNC.md § The Capture-split upload contract).
        await _api.patch('/capture_outcomes/${entry.id}', entry.opData ?? {});
      case ps.UpdateType.delete:
        await _api.delete('/capture_outcomes/${entry.id}');
    }
  }

  Future<void> _uploadCaptureTag(ps.CrudEntry entry) async {
    switch (entry.op) {
      case ps.UpdateType.put:
        final body = Map<String, dynamic>.from(entry.opData ?? {});
        body['id'] = entry.id;
        await _api.post('/capture_tags/', body);
      case ps.UpdateType.patch:
        // capture_tags has no updatable fields; treat as no-op.
        break;
      case ps.UpdateType.delete:
        await _api.delete('/capture_tags/${entry.id}');
    }
  }

  /// Whether removing [entry] from the CRUD queue on a non-retryable error
  /// risks the #306 read-side wipe: a non-delete `user_preferences` write whose
  /// local row survives while the server never hears of it, so the next pull
  /// can delete it. Deletes are exempt — a 404 on DELETE means the row is
  /// already gone, which is idempotent and cannot cause the wipe. Guards a
  /// debug assert in [_recordDeadLetter].
  static bool isSilentDataLossDrop(ps.CrudEntry entry) =>
      entry.table == 'user_preferences' && entry.op != ps.UpdateType.delete;

  /// Per-status upload-error policy (issue #305). The authoritative table
  /// lives in docs/ARCHITECTURE.md § Sync Engine; in brief:
  ///
  ///   - no status (network/timeout), 5xx     → retry (transient)
  ///   - 401                                  → retry — `_AuthRetryInterceptor`
  ///     already refreshed + retried once; a 401 reaching here means the
  ///     refresh itself failed, so the entry stays queued for the next
  ///     backoff cycle. Never dropped.
  ///   - 408, 429                             → retry (timeout / back-pressure)
  ///   - 404 on patch/delete                  → discard — the remote row is
  ///     already gone; the only auto-drop.
  ///   - 404 on put, 403, 409, 400, 422, and
  ///     any other 4xx                        → deadLetter — recorded and
  ///     surfaced, never silently lost.
  static UploadErrorAction classifyUploadError(
      ps.CrudEntry entry, DioException e) {
    final code = e.response?.statusCode;
    if (code == null) return UploadErrorAction.retry;
    if (code == 401 || code == 408 || code == 429) {
      return UploadErrorAction.retry;
    }
    if (code >= 500) return UploadErrorAction.retry;
    if (code == 404 &&
        (entry.op == ps.UpdateType.patch || entry.op == ps.UpdateType.delete)) {
      return UploadErrorAction.discard;
    }
    if (code >= 400) return UploadErrorAction.deadLetter;
    // 1xx–3xx surfaced as a DioException (e.g. a redirect Dio refused to
    // follow) — treat as transient; nothing is ever dropped by default.
    return UploadErrorAction.retry;
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
