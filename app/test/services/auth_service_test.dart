import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/services/api_service.dart';
import 'package:jeeves/services/auth_service.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// In-memory storage — avoids platform-channel dependency on libsecret.
class _FakeStorage implements SecureStorage {
  final Map<String, String> _store = {};

  @override
  Future<String?> read(String key) async => _store[key];

  @override
  Future<void> write(String key, String value) async => _store[key] = value;

  @override
  Future<void> delete(String key) async => _store.remove(key);
}

class _FakeApiService extends ApiService {
  _FakeApiService() : super(baseUrl: 'http://test.invalid');

  String? capturedToken;
  bool tokenCleared = false;

  @override
  void setAuthToken(String token) => capturedToken = token;

  @override
  void clearAuthToken() {
    capturedToken = null;
    tokenCleared = true;
  }
}

// ---------------------------------------------------------------------------
// A scripted socket, so the classification runs over a real Dio
// ---------------------------------------------------------------------------

/// Answers every request with one canned outcome, at Dio's own adapter boundary.
///
/// The real interceptor chain and the real response transformer run — which is
/// the point: `refreshSession`'s verdict is read off a `DioException` Dio built,
/// not off a hand-made one, so a change in how Dio surfaces a body or a header
/// shows up here instead of in production (precedent:
/// `test/sync/http_sync_transport_test.dart`).
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter.answering(this._body) : _failure = null;
  _ScriptedAdapter.failing(this._failure) : _body = null;

  final ResponseBody? _body;
  final DioExceptionType? _failure;

  int requestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount++;
    final failure = _failure;
    if (failure != null) {
      throw DioException(requestOptions: options, type: failure);
    }
    return _body!;
  }

  @override
  void close({bool force = false}) {}
}

const Map<String, List<String>> _jsonHeaders = {
  Headers.contentTypeHeader: [Headers.jsonContentType],
};

/// A [ResponseBody] with the `WWW-Authenticate: Bearer` challenge the backend
/// pairs with every 401 (and that the web build never gets to see — the CORS
/// middleware exposes no headers, which is why the body is the primary signal).
ResponseBody _withChallenge(String body, int status, {String? contentType}) =>
    ResponseBody.fromString(body, status, headers: {
      Headers.contentTypeHeader: [contentType ?? Headers.jsonContentType],
      'www-authenticate': ['Bearer'],
    });

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('AuthService — refreshSession classification', () {
    late _FakeStorage storage;

    /// A service whose `/session/refresh` gets [adapter]'s answer, with a refresh
    /// token already in storage unless [withStoredRefreshToken] says otherwise.
    Future<AuthService> serviceOver(
      _ScriptedAdapter adapter, {
      bool withStoredRefreshToken = true,
    }) async {
      storage = _FakeStorage();
      if (withStoredRefreshToken) {
        await storage.write('refresh_token', 'stored-refresh-token');
      }
      return AuthService(
        apiService: ApiService(baseUrl: 'http://jeeves.invalid', adapter: adapter),
        storage: storage,
      );
    }

    test('a 401 with a JSON detail is the backend rejecting the token', () async {
      final sut = await serviceOver(_ScriptedAdapter.answering(
        ResponseBody.fromString(
          '{"detail": "Invalid or expired refresh token"}',
          401,
          headers: _jsonHeaders,
        ),
      ));
      expect(await sut.refreshSession(), isA<SessionRefreshRejected>());
    });

    test('a 401 whose only signal is the WWW-Authenticate challenge is a '
        'rejection too', () async {
      // The second door: an absent or unparseable body, header present. What a
      // mobile build sees when the backend answers with no JSON at all.
      final sut = await serviceOver(_ScriptedAdapter.answering(
        _withChallenge('', 401, contentType: 'text/plain'),
      ));
      expect(await sut.refreshSession(), isA<SessionRefreshRejected>());
    });

    test('a BARE 401 is inconclusive — it could be any box on the path',
        () async {
      // The captive-portal case. Keying on the status code alone here is what
      // would let a hotel gateway destroy an enrolled device's enrolment.
      final sut = await serviceOver(_ScriptedAdapter.answering(
        ResponseBody.fromString('', 401, headers: const {
          Headers.contentTypeHeader: ['text/plain'],
        }),
      ));
      expect(await sut.refreshSession(), isA<SessionRefreshInconclusive>());
    });

    test('a 401 with an HTML login page is inconclusive', () async {
      final sut = await serviceOver(_ScriptedAdapter.answering(
        ResponseBody.fromString(
          '<html><body>Sign in to continue</body></html>',
          401,
          headers: const {
            Headers.contentTypeHeader: ['text/html; charset=utf-8'],
          },
        ),
      ));
      expect(await sut.refreshSession(), isA<SessionRefreshInconclusive>());
    });

    test('a 401 whose detail is an empty string is inconclusive', () async {
      // Shape, not text — but an empty string is no shape at all.
      final sut = await serviceOver(_ScriptedAdapter.answering(
        ResponseBody.fromString('{"detail": ""}', 401, headers: _jsonHeaders),
      ));
      expect(await sut.refreshSession(), isA<SessionRefreshInconclusive>());
    });

    test('any non-empty detail string corroborates — the text is not matched',
        () async {
      // Deliberate: a copy edit on the backend must not be able to flip every
      // client to never-signing-out.
      final sut = await serviceOver(_ScriptedAdapter.answering(
        ResponseBody.fromString(
          '{"detail": "reformulated wording nobody told the client about"}',
          401,
          headers: _jsonHeaders,
        ),
      ));
      expect(await sut.refreshSession(), isA<SessionRefreshRejected>());
    });

    test('a dead socket is inconclusive', () async {
      final sut =
          await serviceOver(_ScriptedAdapter.failing(DioExceptionType.connectionError));
      expect(await sut.refreshSession(), isA<SessionRefreshInconclusive>());
    });

    test('a connect timeout is inconclusive', () async {
      final sut = await serviceOver(
          _ScriptedAdapter.failing(DioExceptionType.connectionTimeout));
      expect(await sut.refreshSession(), isA<SessionRefreshInconclusive>());
    });

    test('a receive timeout is inconclusive', () async {
      final sut =
          await serviceOver(_ScriptedAdapter.failing(DioExceptionType.receiveTimeout));
      expect(await sut.refreshSession(), isA<SessionRefreshInconclusive>());
    });

    test('a 500 is inconclusive even carrying a detail body and a challenge',
        () async {
      // Only 401 is authoritative. A reverse proxy's 5xx revokes nothing, and the
      // corroborators are not a licence for another status code.
      final sut = await serviceOver(_ScriptedAdapter.answering(
        _withChallenge('{"detail": "upstream exploded"}', 500),
      ));
      expect(await sut.refreshSession(), isA<SessionRefreshInconclusive>());
    });

    test('a 200 missing either token is inconclusive', () async {
      final sut = await serviceOver(_ScriptedAdapter.answering(
        ResponseBody.fromString('{"access_token": "only-one"}', 200,
            headers: _jsonHeaders),
      ));
      expect(await sut.refreshSession(), isA<SessionRefreshInconclusive>());
    });

    test('a 200 with an empty body is inconclusive, not a crash', () async {
      // `ApiService.post` does `response.data!` — the `TypeError` that raises is
      // the reason the classification has an `on Object` arm.
      final sut = await serviceOver(_ScriptedAdapter.answering(
        ResponseBody.fromString('', 200, headers: _jsonHeaders),
      ));
      expect(await sut.refreshSession(), isA<SessionRefreshInconclusive>());
    });

    test('no stored refresh token is authoritative absence, and issues no '
        'request', () async {
      final adapter = _ScriptedAdapter.failing(DioExceptionType.connectionError);
      final sut = await serviceOver(adapter, withStoredRefreshToken: false);
      expect(await sut.refreshSession(), isA<SessionRefreshTokenAbsent>());
      expect(adapter.requestCount, 0);
    });

    test('success rotates both keys in storage', () async {
      final sut = await serviceOver(_ScriptedAdapter.answering(
        ResponseBody.fromString(
          '{"access_token": "fresh-access", "refresh_token": "fresh-refresh"}',
          200,
          headers: _jsonHeaders,
        ),
      ));

      expect(
        await sut.refreshSession(),
        isA<SessionRefreshed>()
            .having((o) => o.accessToken, 'accessToken', 'fresh-access'),
      );
      expect(await storage.read('jwt_token'), 'fresh-access');
      expect(await storage.read('refresh_token'), 'fresh-refresh');
    });

    test('an inconclusive answer leaves both stored keys untouched', () async {
      // The whole #606 fix in one assertion at this layer.
      final sut =
          await serviceOver(_ScriptedAdapter.failing(DioExceptionType.connectionError));
      await sut.refreshSession();
      expect(await storage.read('refresh_token'), 'stored-refresh-token');
    });
  });

  group('AuthService — storage operations', () {
    late _FakeStorage storage;
    late _FakeApiService api;
    late AuthService sut;

    setUp(() {
      storage = _FakeStorage();
      api = _FakeApiService();
      sut = AuthService(apiService: api, storage: storage);
    });

    test('getToken returns null when nothing stored', () async {
      expect(await sut.getToken(), isNull);
    });

    test('saveTokens persists the token and sets it on the api client',
        () async {
      await sut.saveTokens('tok123', 'refresh123');

      expect(await sut.getToken(), 'tok123');
      expect(await sut.getRefreshToken(), 'refresh123');
      expect(api.capturedToken, 'tok123');
    });

    test('clearTokens removes the stored token and clears the api client',
        () async {
      await sut.saveTokens('tok123', 'refresh123');
      await sut.clearTokens();

      expect(await sut.getToken(), isNull);
      expect(await sut.getRefreshToken(), isNull);
      expect(api.capturedToken, isNull);
      expect(api.tokenCleared, isTrue);
    });

    test('getToken round-trips after multiple writes', () async {
      await sut.saveTokens('first', 'r1');
      await sut.saveTokens('second', 'r2');

      expect(await sut.getToken(), 'second');
      expect(await sut.getRefreshToken(), 'r2');
    });

    test('getToken restores API auth state on startup hydration', () async {
      await sut.saveTokens('tok123', 'refresh123');

      // Simulate restart: fresh API client + new service instance, same storage.
      final freshApi = _FakeApiService();
      final freshSut = AuthService(apiService: freshApi, storage: storage);

      final token = await freshSut.getToken();

      expect(token, 'tok123');
      expect(freshApi.capturedToken, 'tok123');
    });
  });
}
