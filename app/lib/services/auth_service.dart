import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_service.dart';

const _kAccessTokenKey = 'jwt_token';
const _kRefreshTokenKey = 'refresh_token';

// ---------------------------------------------------------------------------
// Silent-refresh outcomes
// ---------------------------------------------------------------------------

/// Why a silent refresh ended the way it did.
///
/// Four cases rather than a nullable token, because the caller's decision turns
/// on *which* failure it was: only [SessionRefreshRejected] and
/// [SessionRefreshTokenAbsent] are authoritative, and only they may cost the
/// device its stored credentials. Collapsing a dead socket into the
/// same answer as a server saying "no" is what #606 was — an offline relaunch
/// that destroyed an enrolled device's enrolment and silently dropped the whole
/// session's ops.
sealed class SessionRefreshOutcome {
  const SessionRefreshOutcome();
}

/// The server issued a new access token, and both keys have been rotated in
/// storage.
final class SessionRefreshed extends SessionRefreshOutcome {
  const SessionRefreshed(this.accessToken);

  final String accessToken;
}

/// The Jeeves backend answered 401: the refresh token is revoked, expired,
/// member-scoped or unknown (`backend/app/auth/routes.py`).
///
/// A 401 alone is *not* enough to get here — see [_isCorroboratedRejection].
final class SessionRefreshRejected extends SessionRefreshOutcome {
  const SessionRefreshRejected();
}

/// Anything else — no connection, a timeout, a 5xx, an intercepting proxy, a
/// captive portal, a malformed body, **or an uncorroborated 401**.
///
/// Nothing has been said about the credential's validity, so nothing may be
/// destroyed on the strength of it.
final class SessionRefreshInconclusive extends SessionRefreshOutcome {
  const SessionRefreshInconclusive();
}

/// Nothing was stored to refresh: authoritative absence, and no request made.
final class SessionRefreshTokenAbsent extends SessionRefreshOutcome {
  const SessionRefreshTokenAbsent();
}

/// A 401 from `/session/refresh` this client is willing to act on.
///
/// The status code alone is *any* box on the path — a captive portal, a hotel
/// gateway, an authenticating proxy — and those answer precisely in the offline
/// conditions where destroying an enrolment is most expensive. So the 401 has to
/// be corroborated as the Jeeves backend's own before it is believed; the
/// backend pairs every rejection with both signals below
/// (`backend/app/auth/routes.py`, pinned by `backend/tests/test_sessions.py`).
///
/// **Body-primary, header-secondary, either is enough.** `backend/app/main.py`
/// configures `CORSMiddleware` with no `expose_headers`, and Starlette's default
/// is to expose none, so on the Flutter web build the browser hides
/// `WWW-Authenticate` from Dio entirely. A header-primary rule would therefore
/// classify every genuine 401 as [SessionRefreshInconclusive] on web alone —
/// invisibly to `app/test/`. The JSON body is CORS-safe and is the primary for
/// that reason; the header is the second door for an absent or unparseable body.
///
/// Matched on `detail`'s **shape**, never its text: a copy edit on the backend
/// must not be able to flip every client to never-signing-out.
///
/// Exercised through [AuthService.refreshSession] over a scripted
/// `HttpClientAdapter`, so the response it judges is one Dio itself built — a
/// hand-made `Response` would not catch a change in how Dio surfaces a body or
/// lowercases a header name.
bool _isCorroboratedRejection(Response<dynamic>? response) {
  if (response == null || response.statusCode != 401) return false;

  final data = response.data;
  if (data is Map) {
    final detail = data['detail'];
    if (detail is String && detail.isNotEmpty) return true;
  }

  final challenge = response.headers.value('www-authenticate');
  return challenge != null && challenge.toLowerCase().contains('bearer');
}

/// Minimal storage interface so [AuthService] can be tested without the
/// native secure-storage platform channel.
abstract class SecureStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class _FlutterSecureStorageAdapter implements SecureStorage {
  const _FlutterSecureStorageAdapter(this._storage);
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class AuthService {
  AuthService({
    required ApiService apiService,
    SecureStorage? storage,
  })  : _api = apiService,
        _storage = storage ??
            const _FlutterSecureStorageAdapter(FlutterSecureStorage()) {
    // Wire up the 401 refresh path after both objects are constructed, avoiding
    // a circular provider dependency.
    //
    // Adapted here rather than kept as a second near-homonymous method: the
    // interceptor only needs "a token to retry with, or nothing", and a null
    // means "propagate the original error" (`api_service.dart`). Which *kind* of
    // failure it was matters only to session restore.
    _api.setOnUnauthorized(() async => switch (await refreshSession()) {
          SessionRefreshed(:final accessToken) => accessToken,
          _ => null,
        });
  }

  final ApiService _api;
  final SecureStorage _storage;

  Future<String?> getToken() async {
    final token = await _storage.read(_kAccessTokenKey);
    if (token != null) {
      _api.setAuthToken(token);
    }
    return token;
  }

  Future<String?> getRefreshToken() => _storage.read(_kRefreshTokenKey);

  Future<void> saveTokens(String accessToken, String refreshToken) async {
    await _storage.write(_kAccessTokenKey, accessToken);
    await _storage.write(_kRefreshTokenKey, refreshToken);
    _api.setAuthToken(accessToken);
  }

  Future<void> clearTokens() async {
    _api.clearAuthToken();
    await _storage.delete(_kAccessTokenKey);
    await _storage.delete(_kRefreshTokenKey);
  }

  /// Attempt a silent token refresh using the stored refresh token.
  ///
  /// Says *which* of the four things happened rather than "a token or nothing":
  /// the refresh token is opaque (`backend/app/auth/tokens.py` stores only its
  /// SHA-256 hash), so a client cannot determine locally whether it would be
  /// accepted, and offline the only honest answer is "I don't know". Coding that
  /// as "no" is what #606 was.
  ///
  /// A 200 whose body lacks either token is [SessionRefreshInconclusive] too — a
  /// server that answered 200 with garbage has revoked nothing.
  Future<SessionRefreshOutcome> refreshSession() async {
    final refreshToken = await getRefreshToken();
    if (refreshToken == null) return const SessionRefreshTokenAbsent();
    try {
      final response = await _api.post('/session/refresh', {
        'refresh_token': refreshToken,
      });
      final newAccess = response['access_token'] as String?;
      final newRefresh = response['refresh_token'] as String?;
      if (newAccess == null || newRefresh == null) {
        return const SessionRefreshInconclusive();
      }
      await saveTokens(newAccess, newRefresh);
      return SessionRefreshed(newAccess);
    } on DioException catch (error) {
      return _isCorroboratedRejection(error.response)
          ? const SessionRefreshRejected()
          : const SessionRefreshInconclusive();
    } on Object {
      // A `TypeError` off an empty body, a cast failure on a wrong-typed field,
      // anything a future Dio adds. None of it is the server revoking a
      // credential, so none of it may cost one.
      return const SessionRefreshInconclusive();
    }
  }

  Future<({String accessToken, String refreshToken})> login(
    String email,
    String password,
  ) async {
    final response = await _api.post('/session', {
      'email': email,
      'password': password,
    });
    final access = response['access_token'] as String?;
    final refresh = response['refresh_token'] as String?;
    if (access == null || refresh == null) {
      throw StateError('Server response missing tokens from /session');
    }
    await saveTokens(access, refresh);
    return (accessToken: access, refreshToken: refresh);
  }

  Future<({String accessToken, String refreshToken})> register(
    String email,
    String password,
  ) async {
    final response = await _api.post('/user', {
      'email': email,
      'password': password,
    });
    final access = response['access_token'] as String?;
    final refresh = response['refresh_token'] as String?;
    if (access == null || refresh == null) {
      throw StateError('Server response missing tokens from /user');
    }
    await saveTokens(access, refresh);
    return (accessToken: access, refreshToken: refresh);
  }

  Future<void> logout() async {
    final refreshToken = await getRefreshToken();
    try {
      // Best-effort server-side revocation; don't block if it fails.
      if (_api.isAuthenticated) {
        await _api.delete(
          '/session',
          body: refreshToken != null ? {'refresh_token': refreshToken} : null,
        );
      }
    } catch (_) {}
    await clearTokens();
  }
}

final authServiceProvider = Provider<AuthService>((ref) {
  return AuthService(apiService: ref.watch(apiServiceProvider));
});
