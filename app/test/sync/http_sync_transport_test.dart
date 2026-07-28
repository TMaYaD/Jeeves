/// The HTTP transport's error-parsing path, over a stubbed Dio adapter.
///
/// Everything else in the sync spine is exercised through the in-process double,
/// which raises its typed failures directly. That leaves exactly one thing with
/// no incidental coverage: the *parse* from the server's structured JSON detail
/// into a typed exception. It is the only place where a real server's bytes
/// become the own-writes-rollback verdict's inputs, so a stub adapter is the
/// honest way to hold it to the contract — the parse runs for real, only the
/// socket is replaced.
@TestOn('!browser')
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/http_sync_transport.dart';
import 'package:jeeves/sync/sync_transport.dart';

/// Answers every request with one canned status and body.
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      ResponseBody.fromString(
        body,
        statusCode,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}

const String _workspaceId = '7af3026d-8599-55e0-9861-18d0f42ecbf3';

HttpSyncTransport _transportAnswering(int statusCode, String body) {
  final dio = Dio(BaseOptions(baseUrl: 'http://sync.invalid'))
    ..httpClientAdapter = _CannedAdapter(statusCode, body);
  return HttpSyncTransport(dio, bearerTokenProvider: () async => 'member-token');
}

Future<Object> _postFailure(int statusCode, String body) async {
  final transport = _transportAnswering(statusCode, body);
  try {
    await transport.postOps(_workspaceId, [Uint8List(0)]);
  } on Object catch (error) {
    return error;
  }
  fail('the canned $statusCode should have failed the POST');
}

void main() {
  test('a structured chain conflict parses into its typed exception', () async {
    final error = await _postFailure(
      409,
      '{"detail": {"code": "author_chain_conflict", "index": 3, '
      '"author_seq": 7, "expected_author_seq": 5}}',
    );
    expect(
      error,
      isA<AuthorChainConflictException>()
          .having((e) => e.statusCode, 'statusCode', 409)
          .having((e) => e.code, 'code', authorChainConflictCode)
          .having((e) => e.opIndex, 'opIndex', 3)
          .having((e) => e.submittedAuthorSeq, 'submittedAuthorSeq', 7)
          .having((e) => e.expectedAuthorSeq, 'expectedAuthorSeq', 5),
    );
  });

  test('an omitted expected_author_seq is the no-verdict form', () async {
    // What the race-retry path sends: a raced constraint violation names no
    // position, and a client that invented one would read it as a rollback.
    final error = await _postFailure(409, '{"detail": {"code": "author_chain_conflict"}}');
    expect(
      error,
      isA<AuthorChainConflictException>()
          .having((e) => e.expectedAuthorSeq, 'expectedAuthorSeq', isNull)
          .having((e) => e.submittedAuthorSeq, 'submittedAuthorSeq', isNull)
          .having((e) => e.opIndex, 'opIndex', isNull),
    );
  });

  test('another 409 stays a generic transport failure', () async {
    final error = await _postFailure(
      409,
      '{"detail": {"code": "escrow_version_regression", "stored_version": 4}}',
    );
    expect(error, isA<SyncTransportException>());
    expect(error, isNot(isA<AuthorChainConflictException>()));
    expect((error as SyncTransportException).code, 'escrow_version_regression');
  });

  test('a prose detail still yields a status without inventing a code', () async {
    final error = await _postFailure(409, '{"detail": "conflict"}');
    expect(error, isA<SyncTransportException>());
    expect(error, isNot(isA<AuthorChainConflictException>()));
    expect((error as SyncTransportException).code, isNull);
  });
}
