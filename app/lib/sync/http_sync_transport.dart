/// The two transports over HTTP against `backend/app/sync/routes.py`.
///
/// The production seam, and it is wired up: `providers/sync_stack_provider.dart`
/// builds [HttpUserTransport] over `ApiService`'s session Dio, and the enrolment
/// ceremony reaches it from the phone (#553 Phase 2). [HttpSyncTransport] arrives
/// the only way it can — out of the proof-of-possession exchange below.
///
/// What the live app still does *not* do is push domain writes through here: DAO
/// capture stays `NoopDomainOpCapture` and PowerSync remains the sync path until
/// the flip. The convergence properties are still asserted against the
/// in-process double in `test/sync/harness/`, which is contract-tested
/// case-for-case against these routes.
///
/// [HttpUserTransport] carries the User's session; [HttpSyncTransport] carries
/// a member token and is *only* reachable by completing the proof-of-possession
/// exchange, so there is no way to hold one without having proved possession of
/// the device key it speaks for. The signal socket hangs off the *member*
/// transport for exactly that reason: the server refuses a plain user token
/// there, so a subscription is not something a session alone can open.
///
/// `package:web_socket_channel` carries the signal socket rather than dio,
/// which does not speak WebSocket. It is cross-platform, so #553's platform
/// wiring inherits a working web code path instead of a rewrite; there is no
/// web adapter for the op-log stack in this slice, so the socket is exercised
/// on IO and through the fake.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'signal_socket.dart';
import 'sync_transport.dart';

/// The member-credential surface.
class HttpSyncTransport implements SyncTransport {
  HttpSyncTransport(
    this._dio, {
    required Future<String> Function() bearerTokenProvider,
    Duration idleDeadline = signalIdleDeadline,
    SignalTimerFactory timerFactory = Timer.new,
  })  : _bearerTokenProvider = bearerTokenProvider,
        _idleDeadline = idleDeadline,
        _timerFactory = timerFactory;

  final Dio _dio;

  /// Read once per socket, so a token refreshed between reconnects is picked up
  /// by construction rather than by anyone remembering to re-inject it.
  final Future<String> Function() _bearerTokenProvider;
  final Duration _idleDeadline;
  final SignalTimerFactory _timerFactory;

  @override
  Future<List<OpAppendResult>> postOps(
    String workspaceId,
    List<Uint8List> envelopes,
  ) async {
    final response = await _send(
      () => _dio.post<Map<String, dynamic>>(
        '/w/$workspaceId/ops',
        data: {'ops': [for (final envelope in envelopes) base64Encode(envelope)]},
      ),
    );
    return [
      for (final result in response!['results'] as List<dynamic>)
        OpAppendResult(
          opId: (result as Map<String, dynamic>)['op_id'] as String,
          seq: result['seq'] as int,
          duplicate: result['duplicate'] as bool,
        ),
    ];
  }

  @override
  Future<PullPage> pullOps(
    String workspaceId, {
    required int since,
    required int limit,
  }) async {
    final response = await _send(
      () => _dio.get<Map<String, dynamic>>(
        '/w/$workspaceId/ops',
        queryParameters: {'since': since, 'limit': limit},
      ),
    );
    return PullPage(
      ops: [
        for (final op in response!['ops'] as List<dynamic>)
          PulledOp(
            seq: (op as Map<String, dynamic>)['seq'] as int,
            envelope: base64Decode(op['envelope'] as String),
          ),
      ],
      hasMore: response['has_more'] as bool,
    );
  }

  @override
  Stream<void> newSeqSignals(String workspaceId) => decodeSignalFrames(
        () async {
          final channel = WebSocketChannel.connect(_signalUri(workspaceId));
          try {
            await channel.ready;
          } on Object catch (error) {
            // A failed handshake can still leave a half-open socket, and no
            // `SignalSocket` was handed back, so nothing downstream can close
            // it. Here or never.
            _discardSignalChannel(channel);
            throw SyncTransportException.unreachable('$error');
          }
          // The token goes in the first frame, not a header and not the URL: a
          // browser cannot set `Authorization` on a WebSocket, and a query
          // string would put the token in every proxy and server log.
          final String bearerToken;
          try {
            bearerToken = await _bearerTokenProvider();
          } on Object {
            // The socket is fully open by this point, so a throwing token
            // provider would leak it outright. The error itself is rethrown
            // unmapped: a credential failure is not an unreachable server.
            _discardSignalChannel(channel);
            rethrow;
          }
          channel.sink.add(bearerToken);
          return SignalSocket(
            frames: channel.stream,
            close: () => channel.sink.close(),
            closeCode: () => channel.closeCode,
          );
        },
        idleDeadline: _idleDeadline,
        timerFactory: _timerFactory,
      );

  /// Release a channel that never became a [SignalSocket]. Errors from the
  /// close are discarded rather than swallowed silently by accident: we are
  /// already unwinding a failure, and a close that fails on a socket nobody
  /// holds has nothing left to report.
  static void _discardSignalChannel(WebSocketChannel channel) {
    unawaited(channel.sink.close().catchError((Object _) {}));
  }

  /// Same origin as the REST calls, `http(s)` swapped for `ws(s)`.
  Uri _signalUri(String workspaceId) {
    final base = Uri.parse(_dio.options.baseUrl);
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '${base.path}/w/$workspaceId/signal'.replaceAll('//', '/'),
    );
  }
}

/// The User-credential surface, and the only door to a member credential.
class HttpUserTransport implements UserTransport {
  HttpUserTransport(this._dio);

  final Dio _dio;

  @override
  Future<MemberRecord> registerMember({
    required String memberId,
    required Uint8List signPk,
    required Uint8List kexPk,
  }) async {
    final response = await _send(
      () => _dio.post<Map<String, dynamic>>(
        '/members',
        data: {
          'member_id': memberId,
          'sign_pk': base64Encode(signPk),
          'kex_pk': base64Encode(kexPk),
        },
      ),
    );
    return _memberFromJson(response!);
  }

  @override
  Future<RecoveryEscrowRecord?> fetchRecoveryEscrow(String workspaceId) async {
    try {
      final response = await _send(
        () => _dio.get<Map<String, dynamic>>('/w/$workspaceId/recovery'),
      );
      return _escrowFromJson(response!);
    } on SyncTransportException catch (error) {
      // An empty slot is a state, not a failure: it is what a first device
      // sees. Every other status stays an exception.
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  @override
  Future<RecoveryEscrowRecord> putRecoveryEscrow(
    String workspaceId,
    RecoveryEscrowRecord record,
  ) async {
    final response = await _send(
      () => _dio.put<Map<String, dynamic>>(
        '/w/$workspaceId/recovery',
        data: {
          'version': record.version,
          'blob_b64': base64Encode(record.blob),
          'root_sig_b64': base64Encode(record.rootSig),
          'root_pk_b64': base64Encode(record.rootPk),
        },
      ),
    );
    return _escrowFromJson(response!);
  }

  @override
  Future<Uint8List> requestMemberChallenge(String memberId) async {
    final response = await _send(
      () => _dio.post<Map<String, dynamic>>('/members/$memberId/challenge'),
    );
    return base64Decode(response!['nonce'] as String);
  }

  @override
  Future<SyncTransport> completeMemberChallenge({
    required String memberId,
    required Uint8List nonce,
    required Uint8List signature,
  }) async {
    final response = await _send(
      () => _dio.post<Map<String, dynamic>>(
        '/members/$memberId/token',
        data: {
          'nonce': base64Encode(nonce),
          'signature': base64Encode(signature),
        },
      ),
    );
    // A separate client with a separate credential: the member token must not
    // end up on requests the User credential is for, and vice versa.
    final accessToken = response!['access_token'] as String;
    return HttpSyncTransport(
      Dio(
        _dio.options.copyWith(
          headers: {
            ..._dio.options.headers,
            'Authorization': 'Bearer $accessToken',
          },
        ),
      ),
      // The socket's first frame is this same member token. The server resolves
      // the signal socket through the member-scoped path that the ops routes
      // use, so the credential that can post is the credential that can
      // subscribe — a user session opens neither.
      //
      // A constant closure, not a live lookup: nothing rotates a member token
      // yet (`POST /members/{m}/token/refresh` exists and no client calls it),
      // so there is no fresher value to read. When something does, this is the
      // one line that has to change, and the provider indirection is why.
      bearerTokenProvider: () async => accessToken,
    );
  }

  static MemberRecord _memberFromJson(Map<String, dynamic> json) => MemberRecord(
        memberId: json['member_id'] as String,
        signPk: base64Decode(json['sign_pk'] as String),
        keyId: base64Decode(json['key_id'] as String),
        kexPk: json['kex_pk'] == null ? null : base64Decode(json['kex_pk'] as String),
        chained: json['chained'] as bool? ?? false,
      );

  static RecoveryEscrowRecord _escrowFromJson(Map<String, dynamic> json) =>
      RecoveryEscrowRecord(
        version: json['version'] as int,
        blob: base64Decode(json['blob_b64'] as String),
        rootSig: base64Decode(json['root_sig_b64'] as String),
        rootPk: base64Decode(json['root_pk_b64'] as String),
      );
}

Future<Map<String, dynamic>?> _send(
  Future<Response<Map<String, dynamic>>> Function() request,
) async {
  try {
    return (await request()).data;
  } on DioException catch (error) {
    final status = error.response?.statusCode;
    if (status == null) {
      throw SyncTransportException.unreachable(error.message ?? 'no response');
    }
    throw _failureFor(status, error);
  }
}

/// The typed failure for one HTTP status and its structured detail.
///
/// A chain conflict is the one rejection a caller has to read *fields* off and
/// not merely a code: the own-writes-rollback verdict turns on whether the
/// server's expected position is behind or ahead of what it already
/// acknowledged. Everything else stays a generic [SyncTransportException],
/// including other 409s.
SyncTransportException _failureFor(int status, DioException error) {
  final detail = '${error.response?.data}';
  final code = _codeOf(error);
  if (status == 409 && code == authorChainConflictCode) {
    final fields = _detailOf(error);
    return AuthorChainConflictException(
      detail,
      opIndex: _intOrNull(fields['index']),
      submittedAuthorSeq: _intOrNull(fields['author_seq']),
      expectedAuthorSeq: _intOrNull(fields['expected_author_seq']),
    );
  }
  return SyncTransportException(status, detail, code: code);
}

/// The server's structured `detail` object, or empty when it sent prose.
Map<Object?, Object?> _detailOf(DioException error) {
  final data = error.response?.data;
  if (data is! Map) return const {};
  final detail = data['detail'];
  return detail is Map ? detail : const {};
}

/// The server's structured `detail.code`, when it sent one.
///
/// Every rejection the sync routes raise carries `{"code": ..., ...}`; reading
/// the code rather than the prose is what lets a client branch on *which* rule
/// fired without parsing a sentence.
String? _codeOf(DioException error) {
  final code = _detailOf(error)['code'];
  return code is String ? code : null;
}

/// JSON numbers arrive as `num` from some adapters and `int` from others; a
/// silent null here would read as the no-verdict case, so the coercion is
/// explicit.
int? _intOrNull(Object? value) => value is num ? value.toInt() : null;
