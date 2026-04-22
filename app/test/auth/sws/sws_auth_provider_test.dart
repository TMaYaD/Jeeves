import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/auth/auth_mode.dart';
import 'package:jeeves/auth/auth_provider_interface.dart';
import 'package:jeeves/auth/sws/sws_auth_provider.dart';
import 'package:jeeves/auth/sws/wallet_signer.dart';
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

String _makeJwt(String sub, {int secondsFromNow = 3600}) {
  final header = base64Url.encode(utf8.encode('{"alg":"HS256","typ":"JWT"}'));
  final exp =
      DateTime.now().millisecondsSinceEpoch ~/ 1000 + secondsFromNow;
  final payload = base64Url
      .encode(utf8.encode('{"sub":"$sub","exp":$exp}'))
      .replaceAll('=', '');
  return '$header.$payload.sig';
}

// ---------------------------------------------------------------------------
// Test fixture
// ---------------------------------------------------------------------------

const _testPublicKey = 'FakePublicKey11111111111111111111111111111111';

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

  late ProviderContainer container;
  container = ProviderContainer(overrides: [
    authServiceProvider.overrideWithValue(authService),
    apiServiceProvider.overrideWithValue(api),
    walletSignerProvider.overrideWithValue(
      const StubWalletSigner(publicKey: _testPublicKey),
    ),
    authImplProvider.overrideWith((ref) => SwsAuthProvider(ref)),
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
  group('SwsAuthProvider — signIn', () {
    test('full flow: challenge → sign → token → AuthResult', () async {
      final (:storage, :api, :provider, :container) = _makeFixture();
      addTearDown(container.dispose);

      final accessToken = _makeJwt('solana-user-1');

      // challenge request
      api.respondWith({
        'nonce': 'test-nonce',
        'issued_at': '2026-04-22T00:00:00+00:00',
        'domain': 'jeeves.app',
      });
      // token request
      api.respondWith({
        'access_token': accessToken,
        'refresh_token': 'refresh-xyz',
      });

      final result = await provider.signIn({});

      expect(result.userId, 'solana-user-1');
      expect(result.accessToken, accessToken);
      expect(result.refreshToken, 'refresh-xyz');
    });

    test('throws when challenge fetch fails', () async {
      final (:storage, :api, :provider, :container) = _makeFixture();
      addTearDown(container.dispose);

      api.throwOnNext(Exception('network down'));

      expect(() => provider.signIn({}), throwsA(isA<Exception>()));
    });

    test('throws when token POST returns error', () async {
      final (:storage, :api, :provider, :container) = _makeFixture();
      addTearDown(container.dispose);

      // Challenge succeeds.
      api.respondWith({
        'nonce': 'test-nonce',
        'issued_at': '2026-04-22T00:00:00+00:00',
        'domain': 'jeeves.app',
      });
      // Token POST fails.
      api.throwOnNext(Exception('401 Unauthorized'));

      expect(() => provider.signIn({}), throwsA(isA<Exception>()));
    });
  });

  group('SwsAuthProvider — restore', () {
    test('returns null when no token stored', () async {
      final (:storage, :api, :provider, :container) = _makeFixture();
      addTearDown(container.dispose);

      final result = await provider.restore();
      expect(result, isNull);
    });

    test('returns AuthResult when valid token stored', () async {
      final (:storage, :api, :provider, :container) = _makeFixture();
      addTearDown(container.dispose);

      final token = _makeJwt('solana-user-2');
      await storage.write('jwt_token', token);
      await storage.write('refresh_token', 'rr');

      final result = await provider.restore();

      expect(result, isNotNull);
      expect(result!.userId, 'solana-user-2');
    });
  });
}
