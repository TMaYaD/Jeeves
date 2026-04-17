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

    test('saveToken persists the token and sets it on the api client', () async {
      await sut.saveToken('tok123');

      expect(await sut.getToken(), 'tok123');
      expect(api.capturedToken, 'tok123');
    });

    test('clearToken removes the stored token and clears the api client',
        () async {
      await sut.saveToken('tok123');
      await sut.clearToken();

      expect(await sut.getToken(), isNull);
      expect(api.capturedToken, isNull);
      expect(api.tokenCleared, isTrue);
    });

    test('getToken round-trips after multiple writes', () async {
      await sut.saveToken('first');
      await sut.saveToken('second');

      expect(await sut.getToken(), 'second');
    });
  });
}
