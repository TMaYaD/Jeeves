/// The two transports over HTTP against `backend/app/sync/routes.py`.
///
/// The production seam. Nothing in the app wires it up yet — the sync spine is
/// exercised entirely through the in-process double in `test/sync/harness/`,
/// and the live app stays on PowerSync until #553.
///
/// [HttpUserTransport] carries the User's session; [HttpSyncTransport] carries
/// a member token and is *only* reachable by completing the proof-of-possession
/// exchange, so there is no way to hold one without having proved possession of
/// the device key it speaks for.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'sync_transport.dart';

/// The member-credential surface.
class HttpSyncTransport implements SyncTransport {
  HttpSyncTransport(this._dio);

  final Dio _dio;

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
    throw SyncTransportException(status, '${error.response?.data}', code: _codeOf(error));
  }
}

/// The server's structured `detail.code`, when it sent one.
///
/// Every rejection the sync routes raise carries `{"code": ..., ...}`; reading
/// the code rather than the prose is what lets a client branch on *which* rule
/// fired without parsing a sentence.
String? _codeOf(DioException error) {
  final data = error.response?.data;
  if (data is! Map) return null;
  final detail = data['detail'];
  if (detail is! Map) return null;
  final code = detail['code'];
  return code is String ? code : null;
}
