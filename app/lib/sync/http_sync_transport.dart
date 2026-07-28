/// [SyncTransport] over HTTP against `backend/app/sync/routes.py`.
///
/// The production seam. Nothing in the app wires it up yet — the walking
/// skeleton is exercised entirely through the in-process double in
/// `test/sync/harness/`, and the live app stays on PowerSync until #553.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'sync_transport.dart';

class HttpSyncTransport implements SyncTransport {
  HttpSyncTransport(this._dio);

  final Dio _dio;

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
