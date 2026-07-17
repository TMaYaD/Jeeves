import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:powersync/powersync.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/services/api_service.dart';
import 'package:jeeves/services/backend_connector.dart';
import '../test_helpers.dart';

CrudEntry _entry(String table, UpdateType op,
        {Map<String, dynamic>? opData, String rowId = 'row-id'}) =>
    CrudEntry(1, op, table, rowId, null,
        opData ?? const <String, dynamic>{'title': 'offline write'});

DioException _dioError(int? status, {Object? body}) {
  final request = RequestOptions(path: '/todos/');
  if (status == null) {
    return DioException.connectionError(
        requestOptions: request, reason: 'offline');
  }
  return DioException.badResponse(
    statusCode: status,
    requestOptions: request,
    response: Response(
      requestOptions: request,
      statusCode: status,
      data: body,
    ),
  );
}

/// Scripts HTTP responses at Dio's own boundary ([HttpClientAdapter]) so the
/// real [ApiService] — with its real `_AuthRetryInterceptor` chain — runs
/// end to end without a network. Each request is recorded for assertions.
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this._handler);

  final Future<ResponseBody> Function(RequestOptions options, int callIndex)
      _handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    return _handler(options, requests.length - 1);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonResponse(int status, [String body = '{}']) =>
    ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

void main() {
  setUpAll(configureSqliteForTests);

  group('JevesBackendConnector.classifyUploadError', () {
    // One case per row of the upload-error policy table (docs/ARCHITECTURE.md
    // § Sync Engine). Nothing is ever silently dropped: every 4xx that is not
    // retried or safely discarded must be dead-lettered.
    test('network errors (no status) are retried', () {
      expect(
        JevesBackendConnector.classifyUploadError(
            _entry('todos', UpdateType.put), _dioError(null)),
        UploadErrorAction.retry,
      );
    });

    test('401 is retried — the entry survives a failed token refresh', () {
      expect(
        JevesBackendConnector.classifyUploadError(
            _entry('todos', UpdateType.put), _dioError(401)),
        UploadErrorAction.retry,
      );
    });

    test('408 and 429 are transient back-pressure — retried', () {
      for (final code in [408, 429]) {
        expect(
          JevesBackendConnector.classifyUploadError(
              _entry('todos', UpdateType.put), _dioError(code)),
          UploadErrorAction.retry,
          reason: '$code should be retried',
        );
      }
    });

    test('5xx is retried', () {
      for (final code in [500, 502, 503]) {
        expect(
          JevesBackendConnector.classifyUploadError(
              _entry('todos', UpdateType.put), _dioError(code)),
          UploadErrorAction.retry,
          reason: '$code should be retried',
        );
      }
    });

    test('404 on patch/delete is the only discard — remote row already gone',
        () {
      for (final op in [UpdateType.patch, UpdateType.delete]) {
        expect(
          JevesBackendConnector.classifyUploadError(
              _entry('todos', op), _dioError(404)),
          UploadErrorAction.discard,
          reason: '404 on $op should be discarded',
        );
      }
    });

    test('404 on put is dead-lettered, not discarded', () {
      expect(
        JevesBackendConnector.classifyUploadError(
            _entry('todo_tags', UpdateType.put), _dioError(404)),
        UploadErrorAction.deadLetter,
      );
    });

    test('403, 409, 400, 422 and unknown 4xx are dead-lettered', () {
      for (final code in [400, 403, 409, 418, 422]) {
        expect(
          JevesBackendConnector.classifyUploadError(
              _entry('todos', UpdateType.put), _dioError(code)),
          UploadErrorAction.deadLetter,
          reason: '$code should be dead-lettered',
        );
      }
    });
  });

  group('JevesBackendConnector.uploadCrudBatch', () {
    late GtdDatabase db;

    setUp(() {
      db = GtdDatabase(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    JevesBackendConnector connector(_ScriptedAdapter adapter) {
      final api = ApiService(
        baseUrl: 'http://scripted.invalid',
        adapter: adapter,
      );
      api.setAuthToken('initial-token');
      return JevesBackendConnector(api, db);
    }

    (CrudBatch, bool Function()) batchOf(List<CrudEntry> entries) {
      var completed = false;
      final batch = CrudBatch(
        crud: entries,
        haveMore: false,
        complete: ({String? writeCheckpoint}) async {
          completed = true;
        },
      );
      return (batch, () => completed);
    }

    Future<List<SyncDeadLetter>> deadLetters() =>
        db.select(db.syncDeadLetters).get();

    test(
        '401 with a failing refresh rethrows — entry preserved, '
        'no dead letter (AC-1)', () async {
      final adapter = _ScriptedAdapter((options, i) async => _jsonResponse(401));
      final api = ApiService(
        baseUrl: 'http://scripted.invalid',
        adapter: adapter,
      );
      api.setAuthToken('stale-token');
      api.setOnUnauthorized(() async => null); // refresh fails
      final conn = JevesBackendConnector(api, db);
      final (batch, completed) =
          batchOf([_entry('todos', UpdateType.put)]);

      await expectLater(
        conn.uploadCrudBatch(batch),
        throwsA(isA<DioException>()),
      );
      expect(completed(), isFalse,
          reason: 'the CRUD entry must stay queued through the cycle');
      expect(await deadLetters(), isEmpty);
    });

    test(
        '401 with a succeeding refresh retries with the new token and '
        'uploads (AC-1)', () async {
      final adapter = _ScriptedAdapter((options, i) async =>
          i == 0 ? _jsonResponse(401) : _jsonResponse(201));
      final api = ApiService(
        baseUrl: 'http://scripted.invalid',
        adapter: adapter,
      );
      api.setAuthToken('stale-token');
      api.setOnUnauthorized(() async => 'fresh-token');
      final conn = JevesBackendConnector(api, db);
      final (batch, completed) =
          batchOf([_entry('todos', UpdateType.put)]);

      await conn.uploadCrudBatch(batch);

      expect(adapter.requests, hasLength(2));
      expect(adapter.requests[1].headers['Authorization'],
          'Bearer fresh-token');
      expect(completed(), isTrue);
      expect(await deadLetters(), isEmpty);
    });

    test('404 on patch is discarded — no dead letter (AC-2)', () async {
      final adapter = _ScriptedAdapter((options, i) async => _jsonResponse(404));
      final conn = connector(adapter);
      final (batch, completed) =
          batchOf([_entry('todos', UpdateType.patch)]);

      await conn.uploadCrudBatch(batch);

      expect(completed(), isTrue);
      expect(await deadLetters(), isEmpty);
    });

    test('404 on delete is discarded — no dead letter (AC-2)', () async {
      final adapter = _ScriptedAdapter((options, i) async => _jsonResponse(404));
      final conn = connector(adapter);
      final (batch, completed) =
          batchOf([_entry('todos', UpdateType.delete, opData: null)]);

      await conn.uploadCrudBatch(batch);

      expect(completed(), isTrue);
      expect(await deadLetters(), isEmpty);
    });

    test('404 on put is dead-lettered — recorded, never silent', () async {
      final adapter = _ScriptedAdapter((options, i) async => _jsonResponse(404));
      final conn = connector(adapter);
      final (batch, completed) =
          batchOf([_entry('todo_tags', UpdateType.put)]);

      await conn.uploadCrudBatch(batch);

      expect(completed(), isTrue);
      final rows = await deadLetters();
      expect(rows, hasLength(1));
      expect(rows.single.targetTable, 'todo_tags');
      expect(rows.single.op, 'PUT');
      expect(rows.single.statusCode, 404);
    });

    test('403 and 409 are dead-lettered with table/op/row detail (AC-3)',
        () async {
      for (final code in [403, 409]) {
        final adapter =
            _ScriptedAdapter((options, i) async => _jsonResponse(code));
        final conn = connector(adapter);
        final (batch, completed) =
            batchOf([_entry('tags', UpdateType.put)]);

        await conn.uploadCrudBatch(batch);

        expect(completed(), isTrue, reason: '$code should complete the batch');
        final rows = await deadLetters();
        expect(rows, hasLength(1), reason: '$code should dead-letter');
        expect(rows.single.targetTable, 'tags');
        expect(rows.single.rowId, 'row-id');
        expect(rows.single.statusCode, code);
        await db.delete(db.syncDeadLetters).go();
      }
    });

    test('422 dead letter carries the response body and payload (AC-4)',
        () async {
      final adapter = _ScriptedAdapter((options, i) async =>
          _jsonResponse(422, '{"detail":"clarified must be boolean"}'));
      final conn = connector(adapter);
      final (batch, completed) = batchOf([
        _entry('todos', UpdateType.put,
            opData: {'title': 'buy milk', 'clarified': 'maybe'}),
      ]);

      await conn.uploadCrudBatch(batch);

      expect(completed(), isTrue);
      final rows = await deadLetters();
      expect(rows, hasLength(1));
      expect(rows.single.statusCode, 422);
      expect(rows.single.responseBody, contains('clarified must be boolean'));
      expect(jsonDecode(rows.single.opData!),
          {'title': 'buy milk', 'clarified': 'maybe'});
    });

    test('400 dead letter carries the response body (AC-4)', () async {
      final adapter = _ScriptedAdapter(
          (options, i) async => _jsonResponse(400, '{"detail":"bad request"}'));
      final conn = connector(adapter);
      final (batch, completed) =
          batchOf([_entry('todos', UpdateType.patch)]);

      await conn.uploadCrudBatch(batch);

      expect(completed(), isTrue);
      final rows = await deadLetters();
      expect(rows, hasLength(1));
      expect(rows.single.statusCode, 400);
      expect(rows.single.responseBody, contains('bad request'));
    });

    test('500 rethrows — batch not completed, nothing recorded', () async {
      final adapter = _ScriptedAdapter((options, i) async => _jsonResponse(500));
      final conn = connector(adapter);
      final (batch, completed) =
          batchOf([_entry('todos', UpdateType.put)]);

      await expectLater(
        conn.uploadCrudBatch(batch),
        throwsA(isA<DioException>()),
      );
      expect(completed(), isFalse);
      expect(await deadLetters(), isEmpty);
    });

    test('connection errors rethrow — batch not completed', () async {
      final adapter = _ScriptedAdapter((options, i) async =>
          throw DioException.connectionError(
              requestOptions: options, reason: 'offline'));
      final conn = connector(adapter);
      final (batch, completed) =
          batchOf([_entry('todos', UpdateType.put)]);

      await expectLater(
        conn.uploadCrudBatch(batch),
        throwsA(isA<DioException>()),
      );
      expect(completed(), isFalse);
      expect(await deadLetters(), isEmpty);
    });

    test('a dead-lettered entry does not poison later entries in the batch',
        () async {
      final adapter = _ScriptedAdapter((options, i) async =>
          i == 0 ? _jsonResponse(422, '{"detail":"nope"}') : _jsonResponse(201));
      final conn = connector(adapter);
      final (batch, completed) = batchOf([
        _entry('todos', UpdateType.put, opData: {'title': 'rejected'}),
        _entry('todos', UpdateType.put, opData: {'title': 'accepted'}),
      ]);

      await conn.uploadCrudBatch(batch);

      expect(adapter.requests, hasLength(2),
          reason: 'the second entry must still be attempted');
      expect(completed(), isTrue);
      final rows = await deadLetters();
      expect(rows, hasLength(1));
      expect(jsonDecode(rows.single.opData!)['title'], 'rejected');
    });

    test(
        'a batch retried after a partial failure re-records the same dead '
        'letter once, not twice', () async {
      // Run 1: entry A dead-letters (422), entry B rethrows (500) so the
      // batch is NOT completed. Run 2 (PowerSync's retry re-uploads the
      // whole batch): A 422s again, B succeeds. The repeat dead-letter of A
      // must refresh the existing row, not duplicate it.
      final adapter = _ScriptedAdapter((options, i) async => switch (i) {
            0 => _jsonResponse(422, '{"detail":"first attempt"}'),
            1 => _jsonResponse(500),
            2 => _jsonResponse(422, '{"detail":"second attempt"}'),
            _ => _jsonResponse(201),
          });
      final conn = connector(adapter);
      final entries = [
        _entry('todos', UpdateType.put, rowId: 'row-a'),
        _entry('todos', UpdateType.put, rowId: 'row-b'),
      ];

      final (batch1, completed1) = batchOf(entries);
      await expectLater(
        conn.uploadCrudBatch(batch1),
        throwsA(isA<DioException>()),
      );
      expect(completed1(), isFalse);

      final (batch2, completed2) = batchOf(entries);
      await conn.uploadCrudBatch(batch2);

      expect(completed2(), isTrue);
      final rows = await deadLetters();
      expect(rows, hasLength(1));
      expect(rows.single.rowId, 'row-a');
      expect(rows.single.responseBody, contains('second attempt'),
          reason: 'the repeat occurrence refreshes the recorded body');
    });

    test(
        'the Capture split tables route to their REST endpoints '
        '(not the unknown-table StateError)', () async {
      final adapter = _ScriptedAdapter((options, i) async => _jsonResponse(201));
      final conn = connector(adapter);
      final (batch, completed) = batchOf([
        _entry('captures', UpdateType.put, rowId: 'cap-1'),
        _entry('captures', UpdateType.delete, rowId: 'cap-1'),
        _entry('capture_outcomes', UpdateType.put, rowId: 'co-1'),
        _entry('capture_outcomes', UpdateType.delete, rowId: 'co-1'),
        _entry('capture_tags', UpdateType.put, rowId: 'ct-1'),
        _entry('capture_tags', UpdateType.delete, rowId: 'ct-1'),
      ]);

      await conn.uploadCrudBatch(batch);

      expect(completed(), isTrue);
      final paths = adapter.requests
          .map((r) => '${r.method} ${r.path}')
          .toList();
      expect(paths, [
        'POST /captures/',
        'DELETE /captures/cap-1',
        'POST /capture_outcomes/',
        'DELETE /capture_outcomes/co-1',
        'POST /capture_tags/',
        'DELETE /capture_tags/ct-1',
      ]);
    });

    test(
        'captures and capture_outcomes patches are sent, '
        'capture_tags patch is a no-op like todo_tags', () async {
      final adapter = _ScriptedAdapter((options, i) async => _jsonResponse(200));
      final conn = connector(adapter);
      final (batch, completed) = batchOf([
        _entry('captures', UpdateType.patch, rowId: 'cap-1'),
        _entry('capture_outcomes', UpdateType.patch, rowId: 'co-1'),
        _entry('capture_tags', UpdateType.patch, rowId: 'ct-1'),
      ]);

      await conn.uploadCrudBatch(batch);

      expect(completed(), isTrue);
      expect(
        adapter.requests.map((r) => '${r.method} ${r.path}').toList(),
        ['PATCH /captures/cap-1', 'PATCH /capture_outcomes/co-1'],
      );
    });

    test(
        'dead-lettering a non-delete user_preferences entry trips the #306 '
        'debug assert', () async {
      final adapter = _ScriptedAdapter((options, i) async =>
          _jsonResponse(422, '{"detail":"rejected"}'));
      final conn = connector(adapter);
      final (batch, _) = batchOf([_entry('user_preferences', UpdateType.put)]);

      await expectLater(
        conn.uploadCrudBatch(batch),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('GtdDatabase sync dead letters', () {
    late GtdDatabase db;

    setUp(() {
      db = GtdDatabase(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test('recordSyncDeadLetter prunes the oldest rows beyond the cap',
        () async {
      for (var i = 0; i < GtdDatabase.syncDeadLetterCap + 1; i++) {
        await db.recordSyncDeadLetter(
          tableName: 'todos',
          op: 'PUT',
          rowId: 'row-$i',
          opData: null,
          statusCode: 422,
          responseBody: null,
        );
      }

      final rows = await db.select(db.syncDeadLetters).get();
      expect(rows, hasLength(GtdDatabase.syncDeadLetterCap));
      expect(rows.map((r) => r.rowId), isNot(contains('row-0')),
          reason: 'the oldest row is the one pruned');
    });

    test(
        'pruning goes by last occurrence, not insertion order: a refreshed '
        'repeat outlives newer one-off failures', () async {
      // Fill exactly to the cap; row-0 is the oldest insertion.
      for (var i = 0; i < GtdDatabase.syncDeadLetterCap; i++) {
        await db.recordSyncDeadLetter(
          tableName: 'todos',
          op: 'PUT',
          rowId: 'row-$i',
          opData: null,
          statusCode: 422,
          responseBody: null,
        );
      }

      // row-0's failure repeats — the upsert refreshes its last occurrence.
      await db.recordSyncDeadLetter(
        tableName: 'todos',
        op: 'PUT',
        rowId: 'row-0',
        opData: null,
        statusCode: 422,
        responseBody: null,
      );

      // Overflow with a brand-new failure to force one prune.
      await db.recordSyncDeadLetter(
        tableName: 'todos',
        op: 'PUT',
        rowId: 'row-overflow',
        opData: null,
        statusCode: 422,
        responseBody: null,
      );

      final rowIds =
          (await db.select(db.syncDeadLetters).get()).map((r) => r.rowId);
      expect(rowIds, hasLength(GtdDatabase.syncDeadLetterCap));
      expect(rowIds, contains('row-0'),
          reason: 'the just-refreshed repeat must survive pruning even '
              'though it has the smallest insertion id');
      expect(rowIds, isNot(contains('row-1')),
          reason: 'the stalest last occurrence is the one pruned');
    });

    test(
        'recordSyncDeadLetter de-duplicates repeats of the same failure but '
        'keeps distinct statuses apart', () async {
      await db.recordSyncDeadLetter(
        tableName: 'todos',
        op: 'PUT',
        rowId: 'row-1',
        opData: '{"title":"v1"}',
        statusCode: 422,
        responseBody: '{"detail":"first"}',
      );
      await db.recordSyncDeadLetter(
        tableName: 'todos',
        op: 'PUT',
        rowId: 'row-1',
        opData: '{"title":"v2"}',
        statusCode: 422,
        responseBody: '{"detail":"second"}',
      );

      var rows = await db.select(db.syncDeadLetters).get();
      expect(rows, hasLength(1));
      expect(rows.single.opData, '{"title":"v2"}');
      expect(rows.single.responseBody, '{"detail":"second"}');

      // A different status for the same row is a different failure.
      await db.recordSyncDeadLetter(
        tableName: 'todos',
        op: 'PUT',
        rowId: 'row-1',
        opData: '{"title":"v2"}',
        statusCode: 403,
        responseBody: null,
      );
      rows = await db.select(db.syncDeadLetters).get();
      expect(rows, hasLength(2));
    });

    test('watchSyncDeadLetterCount reflects inserts', () async {
      expect(await db.watchSyncDeadLetterCount().first, 0);

      await db.recordSyncDeadLetter(
        tableName: 'tags',
        op: 'PATCH',
        rowId: 'row-1',
        opData: '{"name":"errands"}',
        statusCode: 409,
        responseBody: null,
      );

      expect(await db.watchSyncDeadLetterCount().first, 1);
    });
  });

  group('JevesBackendConnector.isSilentDataLossDrop', () {
    // The connector's debug assert refuses to silently drop a user_preferences
    // upload on a fatal 4xx (the #306 read-side wipe). These cases lock in which
    // dropped entries trip that guard.
    test('a non-delete user_preferences write trips the guard', () {
      expect(
        JevesBackendConnector.isSilentDataLossDrop(
            _entry('user_preferences', UpdateType.put)),
        isTrue,
      );
      expect(
        JevesBackendConnector.isSilentDataLossDrop(
            _entry('user_preferences', UpdateType.patch)),
        isTrue,
      );
    });

    test('a user_preferences delete is exempt (idempotent 404)', () {
      expect(
        JevesBackendConnector.isSilentDataLossDrop(
            _entry('user_preferences', UpdateType.delete)),
        isFalse,
      );
    });

    test('other tables never trip the guard', () {
      for (final table in [
        'todos',
        'tags',
        'todo_tags',
        'focus_sessions',
        'focus_session_tasks',
        'time_logs',
      ]) {
        for (final op in UpdateType.values) {
          expect(
            JevesBackendConnector.isSilentDataLossDrop(_entry(table, op)),
            isFalse,
            reason: '$table / $op should not be flagged',
          );
        }
      }
    });
  });
}
