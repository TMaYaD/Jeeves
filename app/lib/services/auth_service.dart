import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_service.dart';

const _kTokenKey = 'jwt_token';

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
            const _FlutterSecureStorageAdapter(FlutterSecureStorage());

  final ApiService _api;
  final SecureStorage _storage;

  Future<String?> getToken() async {
    final token = await _storage.read(_kTokenKey);
    if (token != null) {
      _api.setAuthToken(token);
    }
    return token;
  }

  Future<void> saveToken(String token) async {
    await _storage.write(_kTokenKey, token);
    _api.setAuthToken(token);
  }

  Future<void> clearToken() async {
    _api.clearAuthToken();
    await _storage.delete(_kTokenKey);
  }

  Future<String> login(String email, String password) async {
    final response = await _api.post('/session', {
      'email': email,
      'password': password,
    });
    final token = response['access_token'] as String?;
    if (token == null) {
      throw StateError('Server response missing access_token from /session');
    }
    await saveToken(token);
    return token;
  }

  Future<String> register(String email, String password) async {
    final response = await _api.post('/user', {
      'email': email,
      'password': password,
    });
    final token = response['access_token'] as String?;
    if (token == null) {
      throw StateError('Server response missing access_token from /user');
    }
    await saveToken(token);
    return token;
  }
}

final authServiceProvider = Provider<AuthService>((ref) {
  return AuthService(apiService: ref.watch(apiServiceProvider));
});
