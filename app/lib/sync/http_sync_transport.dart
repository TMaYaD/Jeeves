/// [SyncTransport] over HTTP against `backend/app/sync/routes.py`.
///
/// The production seam. Nothing in the app wires it up yet — the walking
/// skeleton is exercised entirely through the in-process double in
/// `test/sync/harness/`, and the live app stays on PowerSync until #553.
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
  Future<MemberRecord> registerMember({
    required String memberId,
    required Uint8List signPk,
  }) async {
    final response = await _send(
      () => _dio.post<Map<String, dynamic>>(
        '/members',
        data: {'member_id': memberId, 'sign_pk': base64Encode(signPk)},
      ),
    );
    return _memberFromJson(response!);
  }

  @override
  Future<List<MemberRecord>> fetchMembers(String workspaceId) async {
    final response = await _send(
      () => _dio.get<Map<String, dynamic>>('/w/$workspaceId/members'),
    );
    return [
      for (final member in response!['members'] as List<dynamic>)
        _memberFromJson(member as Map<String, dynamic>),
    ];
  }

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
            throw SyncTransportException.unreachable('$error');
          }
          // The token goes in the first frame, not a header and not the URL: a
          // browser cannot set `Authorization` on a WebSocket, and a query
          // string would put the token in every proxy and server log.
          channel.sink.add(await _bearerTokenProvider());
          return SignalSocket(
            frames: channel.stream,
            close: () => channel.sink.close(),
            closeCode: () => channel.closeCode,
          );
        },
        idleDeadline: _idleDeadline,
        timerFactory: _timerFactory,
      );

  /// Same origin as the REST calls, `http(s)` swapped for `ws(s)`.
  Uri _signalUri(String workspaceId) {
    final base = Uri.parse(_dio.options.baseUrl);
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '${base.path}/w/$workspaceId/signal'.replaceAll('//', '/'),
    );
  }

  static MemberRecord _memberFromJson(Map<String, dynamic> json) => MemberRecord(
        memberId: json['member_id'] as String,
        signPk: base64Decode(json['sign_pk'] as String),
        keyId: base64Decode(json['key_id'] as String),
      );

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
      throw SyncTransportException(status, '${error.response?.data}');
    }
  }
}
