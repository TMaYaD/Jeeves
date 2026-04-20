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
// Tests
// ---------------------------------------------------------------------------

void main() {
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
