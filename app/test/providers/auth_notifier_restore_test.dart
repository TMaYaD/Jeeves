/// The session decision, isolated: which restore outcomes cost the device its
/// credentials, and which do not.
///
/// Real `AuthNotifier`, real `AuthService`, real `PasswordAuthProvider`, real Dio
/// interceptor chain over a scripted adapter. No sync stack — `_enrolmentGate()`
/// fails open to `SessionGate.ready` by design when the stack cannot be read — so
/// these run in milliseconds and say nothing about the spine.
/// `test/sync/offline_relaunch_session_test.dart` is where the spine's half is
/// proven; this file is where the branch table lives.
///
/// The table (ADR-0041): the arms that clear credentials are a corroborated 401,
/// nothing-stored-to-refresh, and an inconclusive answer that leaves no account id
/// to stay signed in *as* — the torn-secure-store residual of #639, pinned below.
/// Everything else — a dead socket, a 5xx, a bare 401 from a captive portal, a 200
/// full of garbage — keeps the device signed in on credentials of unknown validity,
/// because clearing them destroys an enrolled device's enrolment and drops the
/// whole session's ops (#606). An explicit sign-out still clears, offline or not;
/// that row is the guard against over-correcting.
@TestOn('!browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/auth/auth_mode.dart';
import 'package:jeeves/auth/password/password_auth_provider.dart';
import 'package:jeeves/auth/session_gate.dart';
import 'package:jeeves/providers/auth_provider.dart';
import 'package:jeeves/providers/user_constants.dart';
import 'package:jeeves/services/api_service.dart';
import 'package:jeeves/services/auth_service.dart';

const String _userId = 'restore-user';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeStorage implements SecureStorage {
  final Map<String, String> entries = {};

  @override
  Future<String?> read(String key) async => entries[key];

  @override
  Future<void> write(String key, String value) async => entries[key] = value;

  @override
  Future<void> delete(String key) async => entries.remove(key);
}

/// One canned answer for `/session/refresh`, at Dio's own boundary.
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this._answer);

  /// Null means the socket is dead.
  final ResponseBody? Function() _answer;

  int requestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount++;
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

ResponseBody? _serverError() => ResponseBody.fromString(
    '{"detail": "upstream exploded"}', 500, headers: _jsonHeaders);

ResponseBody? _tokenlessSuccess() => ResponseBody.fromString(
    '{"token_type": "bearer"}', 200, headers: _jsonHeaders);

/// A successful rotation that hands back [accessToken], so the test can name the
/// exact token it expects the notifier to have adopted.
ResponseBody? Function() _refreshedSuccessWith(String accessToken) =>
    () => ResponseBody.fromString(
          jsonEncode({
            'access_token': accessToken,
            'refresh_token': 'rotated-refresh-token',
          }),
          200,
          headers: _jsonHeaders,
        );

// ---------------------------------------------------------------------------
// JWTs
// ---------------------------------------------------------------------------

String _jwt(String sub, {required int secondsFromNow}) {
  final header = base64Url.encode(utf8.encode('{"alg":"HS256","typ":"JWT"}'));
  final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + secondsFromNow;
  final payload = base64Url
      .encode(utf8.encode('{"sub":"$sub","exp":$exp}'))
      .replaceAll('=', '');
  return '$header.$payload.sig';
}

// ---------------------------------------------------------------------------
// Fixture
// ---------------------------------------------------------------------------

typedef _Fixture = ({
  _FakeStorage storage,
  _ScriptedAdapter adapter,
  ProviderContainer container,
});

_Fixture _fixture({
  String? accessToken,
  String? refreshToken,
  ResponseBody? Function() refreshAnswer = _deadSocket,
}) {
  final storage = _FakeStorage();
  if (accessToken != null) storage.entries['jwt_token'] = accessToken;
  if (refreshToken != null) storage.entries['refresh_token'] = refreshToken;

  final adapter = _ScriptedAdapter(refreshAnswer);
  final api = ApiService(baseUrl: 'http://jeeves.invalid', adapter: adapter);

  final container = ProviderContainer(overrides: [
    apiServiceProvider.overrideWithValue(api),
    authServiceProvider
        .overrideWithValue(AuthService(apiService: api, storage: storage)),
    authImplProvider.overrideWith(PasswordAuthProvider.new),
  ]);
  return (storage: storage, adapter: adapter, container: container);
}

void main() {
  setUp(() {
    sessionGateNotifier.value = SessionGate.checking;
    addTearDown(() => sessionGateNotifier.value = SessionGate.checking);
  });

  /// Both stored keys are still there — the assertion #606 is about.
  void expectCredentialsRetained(_FakeStorage storage) {
    expect(storage.entries.containsKey('jwt_token'), isTrue,
        reason: 'the access token was destroyed');
    expect(storage.entries.containsKey('refresh_token'), isTrue,
        reason: 'the refresh token was destroyed — the enrolment is gone');
  }

  void expectCredentialsCleared(_FakeStorage storage) {
    expect(storage.entries.containsKey('jwt_token'), isFalse);
    expect(storage.entries.containsKey('refresh_token'), isFalse);
  }

  group('AuthNotifier.build — an inconclusive refresh keeps the session', () {
    Future<void> expectStaysSignedIn(
      ResponseBody? Function() refreshAnswer, {
      required String because,
    }) async {
      final (:storage, :adapter, :container) = _fixture(
        accessToken: _jwt(_userId, secondsFromNow: -1),
        refreshToken: 'stored-refresh-token',
        refreshAnswer: refreshAnswer,
      );
      addTearDown(container.dispose);

      final token = await container.read(authTokenProvider.future);

      expect(adapter.requestCount, 1, reason: 'the refresh was not attempted');
      expectCredentialsRetained(storage);
      expect(container.read(currentUserIdProvider), _userId, reason: because);
      expect(sessionGateNotifier.value, SessionGate.ready);
      expect(token, isNotNull,
          reason: 'the provider must match the Authorization header already set');
    }

    test('a dead socket — the offline relaunch #606 was reported from', () {
      return expectStaysSignedIn(_deadSocket,
          because: 'an unreachable server reset the device to local-only');
    });

    test('a bare 401 — a captive portal is not the Jeeves backend', () {
      return expectStaysSignedIn(_bare401,
          because: 'a 401 from any box on the path destroyed the session');
    });

    test('an HTTP 500 — a broken server has revoked nothing', () {
      return expectStaysSignedIn(_serverError,
          because: 'a 5xx was read as a rejection');
    });

    test('a 200 with no tokens in it — garbage is not a revocation', () {
      return expectStaysSignedIn(_tokenlessSuccess,
          because: 'a malformed success was read as a rejection');
    });
  });

  group('AuthNotifier.build — the authoritative arms clear', () {
    test('a corroborated 401 signs the device out', () async {
      final (:storage, :adapter, :container) = _fixture(
        accessToken: _jwt(_userId, secondsFromNow: -1),
        refreshToken: 'revoked-refresh-token',
        refreshAnswer: _corroboratedRejection,
      );
      addTearDown(container.dispose);

      expect(await container.read(authTokenProvider.future), isNull);
      expectCredentialsCleared(storage);
      expect(container.read(currentUserIdProvider), kLocalUserId);
      expect(sessionGateNotifier.value, SessionGate.signedOut);
    });

    test('an inconclusive refresh with no recoverable account id still clears',
        () async {
      // The #639 residual, pinned on purpose. A torn secure store — refresh token
      // present, access token absent — leaves no id to stay signed in *as*, so the
      // session cannot be kept even though the answer was inconclusive. Recovering
      // it from the pinned enrolment identity is deferred; a change to this
      // behaviour must change this test deliberately.
      final (:storage, :adapter, :container) = _fixture(
        refreshToken: 'stored-refresh-token',
        refreshAnswer: _deadSocket,
      );
      addTearDown(container.dispose);

      expect(await container.read(authTokenProvider.future), isNull);
      expectCredentialsCleared(storage);
      expect(container.read(currentUserIdProvider), kLocalUserId);
      expect(sessionGateNotifier.value, SessionGate.signedOut);
    });

    test('an unparseable stored access token is the same residual', () async {
      final (:storage, :adapter, :container) = _fixture(
        accessToken: 'not-a-jwt-at-all',
        refreshToken: 'stored-refresh-token',
        refreshAnswer: _deadSocket,
      );
      addTearDown(container.dispose);

      expect(await container.read(authTokenProvider.future), isNull);
      expectCredentialsCleared(storage);
      expect(container.read(currentUserIdProvider), kLocalUserId);
    });

    test('nothing stored at all signs out without throwing', () async {
      final (:storage, :adapter, :container) = _fixture();
      addTearDown(container.dispose);

      expect(await container.read(authTokenProvider.future), isNull);
      expect(adapter.requestCount, 0,
          reason: 'a device with no refresh token asked the server anyway');
      expect(container.read(currentUserIdProvider), kLocalUserId);
      expect(sessionGateNotifier.value, SessionGate.signedOut);
    });
  });

  group('AuthNotifier.build — the happy paths are unchanged', () {
    test('a valid stored access token is adopted without a refresh', () async {
      final token = _jwt(_userId, secondsFromNow: 3600);
      final (:storage, :adapter, :container) = _fixture(
        accessToken: token,
        refreshToken: 'stored-refresh-token',
      );
      addTearDown(container.dispose);

      expect(await container.read(authTokenProvider.future), token);
      expect(adapter.requestCount, 0);
      expectCredentialsRetained(storage);
      expect(container.read(currentUserIdProvider), _userId);
      expect(sessionGateNotifier.value, SessionGate.ready);
    });

    test('an expired token that refreshes successfully rotates and stays in',
        () async {
      final rotatedAccessToken = _jwt(_userId, secondsFromNow: 3600);
      final staleStoredToken = _jwt(_userId, secondsFromNow: -1);
      final (:storage, :adapter, :container) = _fixture(
        accessToken: staleStoredToken,
        refreshToken: 'stored-refresh-token',
        refreshAnswer: _refreshedSuccessWith(rotatedAccessToken),
      );
      addTearDown(container.dispose);

      // Pinned exactly, not merely non-null: the stale stored token is non-null
      // too, so `isNotNull` would pass whether or not the rotation was adopted.
      expect(await container.read(authTokenProvider.future), rotatedAccessToken);
      expect(storage.entries['jwt_token'], rotatedAccessToken);
      expect(storage.entries['refresh_token'], 'rotated-refresh-token');
      expect(container.read(currentUserIdProvider), _userId);
      expect(sessionGateNotifier.value, SessionGate.ready);
    });
  });

  group('AuthNotifier.logout', () {
    test('an explicit sign-out still clears, with no network', () async {
      // The over-correction guard. Retaining credentials through an inconclusive
      // *refresh* must not turn into retaining them through a user decision.
      final (:storage, :adapter, :container) = _fixture(
        accessToken: _jwt(_userId, secondsFromNow: 3600),
        refreshToken: 'stored-refresh-token',
      );
      addTearDown(container.dispose);

      await container.read(authTokenProvider.future);
      expect(container.read(currentUserIdProvider), _userId);

      await container.read(authTokenProvider.notifier).logout();

      expectCredentialsCleared(storage);
      expect(container.read(currentUserIdProvider), kLocalUserId);
      expect(sessionGateNotifier.value, SessionGate.signedOut);
    });
  });
}
