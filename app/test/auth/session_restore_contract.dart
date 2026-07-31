/// The restore contract every JWT-bearing [AuthProvider] owes, run against each
/// of them.
///
/// Both providers delegate to `restoreJwtSession`, so on today's tree these cases
/// exercise one implementation twice. That is the point: their `restore()` bodies
/// used to be near-identical thirty-line copies, and #606 lived in both of them —
/// a fix applied to one would have left the other destroying an enrolled device's
/// credentials on an offline relaunch. Parametrising the contract means a future
/// provider that re-implements restore has to satisfy it, and a divergence
/// between the two shows up as a failure rather than as a platform-specific bug.
///
/// The scripted [HttpClientAdapter] sits at Dio's own boundary, so the real
/// `ApiService` interceptor chain and response transformer run and the verdict is
/// read off a `DioException` Dio itself built.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/auth/auth_mode.dart';
import 'package:jeeves/auth/auth_provider_interface.dart';
import 'package:jeeves/auth/session_restore.dart';
import 'package:jeeves/services/api_service.dart';
import 'package:jeeves/services/auth_service.dart';

const String contractUserId = 'contract-user';

class _FakeStorage implements SecureStorage {
  final Map<String, String> entries = {};

  @override
  Future<String?> read(String key) async => entries[key];

  @override
  Future<void> write(String key, String value) async => entries[key] = value;

  @override
  Future<void> delete(String key) async => entries.remove(key);
}

class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this._answer);

  final ResponseBody? Function() _answer;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final answer = _answer();
    if (answer == null) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'network is unreachable',
      );
    }
    return answer;
  }

  @override
  void close({bool force = false}) {}
}

const Map<String, List<String>> _jsonHeaders = {
  Headers.contentTypeHeader: [Headers.jsonContentType],
};

ResponseBody? _deadSocket() => null;

ResponseBody? _corroboratedRejection() => ResponseBody.fromString(
      '{"detail": "Invalid or expired refresh token"}',
      401,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        'www-authenticate': ['Bearer'],
      },
    );

ResponseBody? _bare401() =>
    ResponseBody.fromString('', 401, headers: const {
      Headers.contentTypeHeader: ['text/plain'],
    });

String contractJwt(String sub, {required int secondsFromNow}) {
  final header = base64Url.encode(utf8.encode('{"alg":"HS256","typ":"JWT"}'));
  final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + secondsFromNow;
  final payload = base64Url
      .encode(utf8.encode('{"sub":"$sub","exp":$exp}'))
      .replaceAll('=', '');
  return '$header.$payload.sig';
}

/// Every case both providers must satisfy, run under `<label> — restore
/// contract`.
///
/// [buildProvider] is the provider's own constructor, so the implementation under
/// test is the production one wired through `authImplProvider`.
void runSessionRestoreContract(
  String label,
  AuthProvider Function(Ref) buildProvider,
) {
  ({_FakeStorage storage, AuthProvider provider, ProviderContainer container})
      fixture({
    String? accessToken,
    String? refreshToken,
    ResponseBody? Function() refreshAnswer = _deadSocket,
  }) {
    final storage = _FakeStorage();
    if (accessToken != null) storage.entries['jwt_token'] = accessToken;
    if (refreshToken != null) storage.entries['refresh_token'] = refreshToken;

    final api = ApiService(
      baseUrl: 'http://jeeves.invalid',
      adapter: _ScriptedAdapter(refreshAnswer),
    );
    final container = ProviderContainer(overrides: [
      apiServiceProvider.overrideWithValue(api),
      authServiceProvider
          .overrideWithValue(AuthService(apiService: api, storage: storage)),
      authImplProvider.overrideWith(buildProvider),
    ]);
    addTearDown(container.dispose);
    return (
      storage: storage,
      provider: container.read(authImplProvider),
      container: container,
    );
  }

  group('$label — restore contract', () {
    test('a stored unexpired token restores without asking the server',
        () async {
      final token = contractJwt(contractUserId, secondsFromNow: 3600);
      final (:storage, :provider, :container) =
          fixture(accessToken: token, refreshToken: 'r');

      expect(
        await provider.restore(),
        isA<SessionRestored>()
            .having((o) => o.session.userId, 'userId', contractUserId)
            .having((o) => o.session.accessToken, 'accessToken', token)
            .having((o) => o.session.refreshToken, 'refreshToken', 'r'),
      );
    });

    test('an expired token that refreshes restores on the new one', () async {
      final refreshed = contractJwt(contractUserId, secondsFromNow: 3600);
      final (:storage, :provider, :container) = fixture(
        accessToken: contractJwt(contractUserId, secondsFromNow: -1),
        refreshToken: 'old-refresh',
        refreshAnswer: () => ResponseBody.fromString(
          jsonEncode({'access_token': refreshed, 'refresh_token': 'new-refresh'}),
          200,
          headers: _jsonHeaders,
        ),
      );

      expect(
        await provider.restore(),
        isA<SessionRestored>()
            .having((o) => o.session.userId, 'userId', contractUserId)
            .having((o) => o.session.accessToken, 'accessToken', refreshed),
      );
      expect(storage.entries['refresh_token'], 'new-refresh');
    });

    test('an unreachable server is UNVERIFIED, and keeps both keys', () async {
      // #606: the answer is "I don't know", and it must not cost the enrolment.
      final expired = contractJwt(contractUserId, secondsFromNow: -1);
      final (:storage, :provider, :container) =
          fixture(accessToken: expired, refreshToken: 'r');

      expect(
        await provider.restore(),
        isA<SessionUnverified>()
            .having((o) => o.userId, 'userId', contractUserId)
            .having((o) => o.expiredAccessToken, 'expiredAccessToken', expired),
      );
      expect(storage.entries['jwt_token'], expired);
      expect(storage.entries['refresh_token'], 'r');
    });

    test('a bare 401 is UNVERIFIED too — it is not the backend answering',
        () async {
      final (:storage, :provider, :container) = fixture(
        accessToken: contractJwt(contractUserId, secondsFromNow: -1),
        refreshToken: 'r',
        refreshAnswer: _bare401,
      );

      expect(await provider.restore(), isA<SessionUnverified>());
      expect(storage.entries['refresh_token'], 'r');
    });

    test('a 200 without tokens is UNVERIFIED, and keeps both keys', () async {
      // A malformed success is exactly the shape the inversion exists to catch:
      // promoting it to ABSENT would clear an enrolled device's credentials on
      // nothing more authoritative than a broken response body.
      final expired = contractJwt(contractUserId, secondsFromNow: -1);
      final (:storage, :provider, :container) = fixture(
        accessToken: expired,
        refreshToken: 'r',
        refreshAnswer: () => ResponseBody.fromString(
          jsonEncode(<String, Object?>{}),
          200,
          headers: _jsonHeaders,
        ),
      );

      expect(await provider.restore(), isA<SessionUnverified>());
      expect(storage.entries['jwt_token'], expired);
      expect(storage.entries['refresh_token'], 'r');
    });

    test('a corroborated 401 is ABSENT', () async {
      final (:storage, :provider, :container) = fixture(
        accessToken: contractJwt(contractUserId, secondsFromNow: -1),
        refreshToken: 'r',
        refreshAnswer: _corroboratedRejection,
      );

      expect(await provider.restore(), isA<SessionAbsent>());
    });

    test('nothing stored is ABSENT', () async {
      final (:storage, :provider, :container) = fixture();
      expect(await provider.restore(), isA<SessionAbsent>());
    });

    test('an expired token with no refresh token is ABSENT', () async {
      final (:storage, :provider, :container) =
          fixture(accessToken: contractJwt(contractUserId, secondsFromNow: -1));
      expect(await provider.restore(), isA<SessionAbsent>());
    });

    test('an unreachable server with no recoverable account id is ABSENT',
        () async {
      // The torn-secure-store residual (#639), pinned deliberately: inconclusive,
      // but there is no id to stay signed in as.
      final (:storage, :provider, :container) =
          fixture(accessToken: 'not-a-jwt', refreshToken: 'r');
      expect(await provider.restore(), isA<SessionAbsent>());
    });
  });
}
