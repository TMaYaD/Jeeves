import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_service.dart';

const _kAccessTokenKey = 'jwt_token';
const _kRefreshTokenKey = 'refresh_token';

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
    _api.setOnUnauthorized(refreshSession);
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
  /// Returns the new access token on success, or null if the refresh token is
  /// missing, expired, or the server rejects it.
  Future<String?> refreshSession() async {
    final refreshToken = await getRefreshToken();
    if (refreshToken == null) return null;
    try {
      final response = await _api.post('/session/refresh', {
        'refresh_token': refreshToken,
      });
      final newAccess = response['access_token'] as String?;
      final newRefresh = response['refresh_token'] as String?;
      if (newAccess == null || newRefresh == null) return null;
      await saveTokens(newAccess, newRefresh);
      return newAccess;
    } catch (_) {
      return null;
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

  /// Check whether the server has any todos for the current authenticated user.
  Future<bool> serverHasTodos() async {
    try {
      final todos = await _api.getList('/todos/');
      return todos.isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}

final authServiceProvider = Provider<AuthService>((ref) {
  return AuthService(apiService: ref.watch(apiServiceProvider));
});
