/// The resume's refusal table, over both of its server calls.
///
/// Pure: no database, no clock, no server. That is the point of factoring
/// `rotation_resume_refusal.dart` out — the whole table can be walked here, and the
/// end-to-end consequences of each verdict live in `rotation_resume_test.dart`.
///
/// One case does reach for the real HTTP transport, and deliberately: a FastAPI
/// `RequestValidationError` sends a **list** `detail`, so the production parser
/// yields `code == null`. That shape is exercised through the real parse rather
/// than described, because an unparsed detail is exactly how an unclassified code
/// slips through.
@TestOn('!browser')
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/http_sync_transport.dart';
import 'package:jeeves/sync/rotation_resume_refusal.dart';
import 'package:jeeves/sync/sync_transport.dart';

const String _workspaceId = '7af3026d-8599-55e0-9861-18d0f42ecbf3';

RotationResumeDisposition _publish(int? status, {String? code}) =>
    dispositionForResumeRefusal(
      status == null
          ? const SyncTransportException.unreachable('offline')
          : SyncTransportException(status, 'detail', code: code),
      surface: RotationResumeSurface.publish,
    );

RotationResumeDisposition _flush(int? status, {String? code}) =>
    dispositionForResumeRefusal(
      status == null
          ? const SyncTransportException.unreachable('offline')
          : SyncTransportException(status, 'detail', code: code),
      surface: RotationResumeSurface.flush,
    );

/// Answers every request with one canned status and body, so the *parse* runs for
/// real and only the socket is replaced — the `http_sync_transport_test.dart` idiom.
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

Future<SyncTransportException> _putKeyWrapsFailure(
  int statusCode,
  String body,
) async {
  final dio = Dio(BaseOptions(baseUrl: 'http://sync.invalid'))
    ..httpClientAdapter = _CannedAdapter(statusCode, body);
  final transport =
      HttpSyncTransport(dio, bearerTokenProvider: () async => 'member-token');
  try {
    await transport.putKeyWraps(
      _workspaceId,
      epoch: 1,
      wraps: const [],
      escrowWrap: Uint8List(0),
    );
  } on SyncTransportException catch (error) {
    return error;
  }
  fail('the canned $statusCode should have failed the PUT');
}

void main() {
  group('publish surface — PUT /w/{w}/keywraps', () {
    test('rotate_not_materialised is the one discard', () {
      // Nothing has committed to a digest, so nothing is stranded by dropping the
      // record: the owner re-runs the ceremony fresh with new entropy.
      expect(_publish(409, code: rotateNotMaterialisedCode),
          RotationResumeDisposition.discard);
    });

    test('every deterministic keywraps refusal is permanent', () {
      // Read off `put_keywraps` in `backend/app/sync/routes.py`. Each is a verdict on
      // bytes that are already fixed — the digest the log committed to, or a field
      // that digest covers — so no retry can change the answer.
      for (final code in [
        keyWrapDigestMismatchCode,
        'keywrap_already_written',
        'malformed_key_epoch',
        'malformed_escrow_wrap',
        'malformed_keywrap',
        'malformed_kex_key_id',
        'malformed_keywrap_digest',
        'missing_keywrap_digest',
        'duplicate_keywrap_member',
        'unknown_keywrap_member',
        'kex_key_id_not_registered',
      ]) {
        expect(_publish(422, code: code), RotationResumeDisposition.permanent,
            reason: '$code is deterministic');
      }
      expect(_publish(409, code: 'keywrap_already_written'),
          RotationResumeDisposition.permanent);
      expect(_publish(403, code: workspaceNotDerivableCode),
          RotationResumeDisposition.permanent,
          reason: 'the v1 Workspace id space is closed and no retry widens it');
    });

    test('the two remaining 403s are known-unclassified, not overlooked', () {
      // Listed in `knownUnclassifiedResumeRefusalCodes` on purpose: a revoked or
      // non-owner Device is a dead end for *this* credential, which a re-grant could
      // revive, and the bounded verdict costs nothing durable.
      expect(knownUnclassifiedResumeRefusalCodes,
          containsAll(<String>{'keywrap_requires_owner', noLiveGrantRefusalCode}));
      for (final code in knownUnclassifiedResumeRefusalCodes) {
        expect(_publish(403, code: code), RotationResumeDisposition.retryBounded);
      }
    });
  });

  group('flush surface — POST /w/{w}/ops', () {
    test('rotate_epoch_conflict is permanent', () {
      // The loser of a rotation race. `from_epoch` is signed into the statement, so
      // it can never become where the Workspace actually stands.
      expect(_flush(409, code: rotateEpochConflictCode),
          RotationResumeDisposition.permanent);
    });

    test('a signed header the Workspace has moved past is permanent', () {
      expect(_flush(409, code: 'key_epoch_stale'),
          RotationResumeDisposition.permanent);
      expect(_flush(409, code: 'key_epoch_unknown'),
          RotationResumeDisposition.permanent);
      expect(_flush(409, code: 'workspace_not_created'),
          RotationResumeDisposition.permanent);
      expect(_flush(422, code: 'member_register_not_first'),
          RotationResumeDisposition.permanent);
      expect(_flush(422, code: 'control_chain_break'),
          RotationResumeDisposition.permanent);
      expect(_flush(403, code: workspaceNotDerivableCode),
          RotationResumeDisposition.permanent);
      expect(_flush(403, code: noLiveGrantRefusalCode),
          RotationResumeDisposition.permanent);
    });

    test('rotate_not_materialised has no meaning here and is never a discard', () {
      // `discard` deletes a *pending record*, which a flush verdict may never do:
      // the flush is one call per Workspace and blames no single epoch.
      expect(_flush(409, code: rotateNotMaterialisedCode),
          isNot(RotationResumeDisposition.discard));
    });
  });

  group('shared rules', () {
    test('a refusal that carries no verdict is an unbounded retry', () {
      for (final surface in RotationResumeSurface.values) {
        final of = surface == RotationResumeSurface.publish ? _publish : _flush;
        expect(of(null), RotationResumeDisposition.retry,
            reason: 'unreachable is the offline case');
        for (final status in [500, 502, 503, 504, 408, 429, 401]) {
          expect(of(status), RotationResumeDisposition.retry,
              reason: '$status is the server failing or asking again, not judging');
        }
      }
    });

    test('there is no `default: retry` — an unknown code is bounded on both '
        'surfaces', () {
      // The property the whole module exists for. A future server code cannot join
      // the retry-forever path that #627 is about, on either surface.
      for (final surface in RotationResumeSurface.values) {
        final of = surface == RotationResumeSurface.publish ? _publish : _flush;
        expect(of(418, code: 'not_a_code_this_build_knows'),
            RotationResumeDisposition.retryBounded);
        expect(of(422, code: 'invented_next_quarter'),
            RotationResumeDisposition.retryBounded);
        expect(of(400), RotationResumeDisposition.retryBounded,
            reason: 'a 4xx with no structured code is unnameable, not transient');
        expect(of(403), RotationResumeDisposition.retryBounded);
      }
    });
  });

  group('a list-shaped detail, through the real parser', () {
    test("FastAPI's RequestValidationError yields a null code and a bounded "
        'verdict', () async {
      // The literal body FastAPI sends when the request model itself fails to
      // validate: `detail` is a *list*, so `_detailOf` returns `{}` and `_codeOf`
      // returns null. Exercised rather than described.
      final refusal = await _putKeyWrapsFailure(
        422,
        '{"detail": [{"type": "missing", "loc": ["body", "epoch"], '
        '"msg": "Field required", "input": {}}]}',
      );
      expect(refusal.statusCode, 422);
      expect(refusal.code, isNull,
          reason: 'a list detail has no `code` to read, and the parser does not '
              'invent one');
      expect(
        dispositionForResumeRefusal(refusal,
            surface: RotationResumeSurface.publish),
        RotationResumeDisposition.retryBounded,
        reason: 'unnameable is bounded, not transient — an unparsed detail is '
            'exactly how an unclassified code slips through',
      );
    });

    test('a string detail is the same case', () async {
      // The other shape FastAPI sends: `detail` is prose rather than the structured
      // object the sync routes use, so again there is no code to read.
      final refusal =
          await _putKeyWrapsFailure(422, '{"detail": "something went wrong"}');
      expect(refusal.code, isNull);
      expect(
        dispositionForResumeRefusal(refusal, surface: RotationResumeSurface.flush),
        RotationResumeDisposition.retryBounded,
      );
    });
  });
}
