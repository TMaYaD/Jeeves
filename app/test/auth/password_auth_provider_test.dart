import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/auth/auth_mode.dart';
import 'package:jeeves/auth/auth_provider_interface.dart';
import 'package:jeeves/auth/password/password_auth_provider.dart';
import 'package:jeeves/services/api_service.dart';
import 'package:jeeves/services/auth_service.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

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

  final List<Map<String, dynamic>> _responses = [];
  final List<Exception> _errors = [];

  void respondWith(Map<String, dynamic> data) => _responses.add(data);
  void throwOnNext(Exception e) => _errors.add(e);

  @override
  void setAuthToken(String token) {}

  @override
  void clearAuthToken() {}

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (_errors.isNotEmpty) throw _errors.removeAt(0);
    return _responses.removeAt(0);
  }
}

// ---------------------------------------------------------------------------
// JWT helpers for tests
// ---------------------------------------------------------------------------

/// Build a minimal valid JWT with the given [sub] and expiry [secondsFromNow].
String _makeJwt(String sub, {int secondsFromNow = 3600}) {
  final header = base64Url.encode(utf8.encode('{"alg":"HS256","typ":"JWT"}'));
  final exp =
      DateTime.now().millisecondsSinceEpoch ~/ 1000 + secondsFromNow;
  final payload = base64Url
      .encode(utf8.encode('{"sub":"$sub","exp":$exp}'))
      .replaceAll('=', '');
  return '$header.$payload.sig';
}

String _makeExpiredJwt(String sub) => _makeJwt(sub, secondsFromNow: -1);

// ---------------------------------------------------------------------------
// Helper: build a ProviderContainer with fakes and read the AuthProvider
// ---------------------------------------------------------------------------

typedef _Fixture = ({
  _FakeStorage storage,
  _FakeApiService api,
  AuthProvider provider,
  ProviderContainer container,
});

_Fixture _makeFixture() {
  final storage = _FakeStorage();
  final api = _FakeApiService();
  final authService = AuthService(apiService: api, storage: storage);

  // Override authImplProvider so we get a real PasswordAuthProvider with the
  // fake services injected.
  late ProviderContainer container;
  container = ProviderContainer(overrides: [
    authServiceProvider.overrideWithValue(authService),
    authImplProvider.overrideWith(
      (ref) => PasswordAuthProvider(ref),
    ),
  ]);

  final provider = container.read(authImplProvider);
  return (
    storage: storage,
    api: api,
    provider: provider,
    container: container,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('PasswordAuthProvider — signIn', () {
    test('happy path returns AuthResult with userId decoded from JWT', () async {
      final (:storage, :api, :provider, :container) = _makeFixture();
      addTearDown(container.dispose);

      final token = _makeJwt('user-123');
      api.respondWith({'access_token': token, 'refresh_token': 'r'});

      final result = await provider.signIn({'email': 'a@b.com', 'password': 'secret'});

      expect(result.accessToken, token);
      expect(result.refreshToken, 'r');
      expect(result.userId, 'user-123');
    });

    test('propagates API errors', () async {
      final (:storage, :api, :provider, :container) = _makeFixture();
      addTearDown(container.dispose);

      api.throwOnNext(Exception('network error'));

      expect(
        () => provider.signIn({'email': 'a@b.com', 'password': 'x'}),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('PasswordAuthProvider — restore', () {
    test('returns AuthResult when valid access token is stored', () async {
      final (:storage, :api, :provider, :container) = _makeFixture();
      addTearDown(container.dispose);

      final token = _makeJwt('user-42');
      await storage.write('jwt_token', token);
      await storage.write('refresh_token', 'r42');

      final result = await provider.restore();

      expect(result, isNotNull);
      expect(result!.userId, 'user-42');
      expect(result.accessToken, token);
    });

    test('returns null when no token stored and refresh also fails', () async {
      final (:storage, :api, :provider, :container) = _makeFixture();
      addTearDown(container.dispose);

      final result = await provider.restore();
      expect(result, isNull);
    });

    test('returns null when access token expired and no refresh token',
        () async {
      final (:storage, :api, :provider, :container) = _makeFixture();
      addTearDown(container.dispose);

      await storage.write('jwt_token', _makeExpiredJwt('user-99'));
      // No refresh token stored → refreshSession returns null.
      final result = await provider.restore();
      expect(result, isNull);
    });

    test('silently refreshes when access token is expired', () async {
      final (:storage, :api, :provider, :container) = _makeFixture();
      addTearDown(container.dispose);

      await storage.write('jwt_token', _makeExpiredJwt('user-99'));
      await storage.write('refresh_token', 'old-refresh');

      final newToken = _makeJwt('user-99');
      api.respondWith({'access_token': newToken, 'refresh_token': 'new-refresh'});

      final result = await provider.restore();

      expect(result, isNotNull);
      expect(result!.userId, 'user-99');
    });
  });

  group('PasswordAuthProvider — signOut', () {
    test('clears tokens from storage', () async {
      final (:storage, :api, :provider, :container) = _makeFixture();
      addTearDown(container.dispose);

      final token = _makeJwt('user-1');
      await storage.write('jwt_token', token);
      await storage.write('refresh_token', 'r');

      await provider.signOut('r');

      expect(await storage.read('jwt_token'), isNull);
      expect(await storage.read('refresh_token'), isNull);
    });
  });
}
