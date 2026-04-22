import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/api_service.dart';
import '../../services/auth_service.dart';
import '../auth_provider_interface.dart';
import '../jwt_utils.dart';
import 'sws_login_widget.dart';
import 'wallet_signer.dart';

// ---------------------------------------------------------------------------
// Wallet signer provider
// ---------------------------------------------------------------------------

/// Override this in tests with a [StubWalletSigner].
final walletSignerProvider = Provider<WalletSigner>((ref) {
  return const SeedVaultSigner();
});

// ---------------------------------------------------------------------------
// SIWS message template
// ---------------------------------------------------------------------------

/// Reconstructed identically in the backend's `sws_strategy.py`.
String _buildSiwsMessage({
  required String publicKey,
  required String nonce,
  required String issuedAt,
}) =>
    'jeeves.app wants you to sign in with your Solana account:\n'
    '$publicKey\n'
    '\n'
    'Sign in to Jeeves\n'
    '\n'
    'URI: https://jeeves.app\n'
    'Version: 1\n'
    'Chain ID: solana:mainnet\n'
    'Nonce: $nonce\n'
    'Issued At: $issuedAt';

// ---------------------------------------------------------------------------
// SWS auth provider
// ---------------------------------------------------------------------------

/// [AuthProvider] implementation for Sign-In With Solana (SWS).
///
/// Full flow:
/// 1. `POST /auth/sws/challenge` → `{nonce, issuedAt, domain}`
/// 2. Build the SIWS message string.
/// 3. [WalletSigner.sign] the UTF-8 message bytes.
/// 4. `POST /auth/sws {publicKey, signature (base64), nonce}` → tokens.
/// 5. Persist tokens via [AuthService]; return [AuthResult].
class SwsAuthProvider implements AuthProvider {
  const SwsAuthProvider(this._ref);

  final Ref _ref;

  ApiService get _api => _ref.read(apiServiceProvider);
  AuthService get _authService => _ref.read(authServiceProvider);
  WalletSigner get _signer => _ref.read(walletSignerProvider);

  @override
  Widget buildLoginWidget(BuildContext context) => const SwsLoginWidget();

  @override
  Future<AuthResult> signIn(Map<String, dynamic> params) async {
    // Step 1: obtain a challenge nonce.
    // We need the public key to bind the nonce.  Ask the signer to sign an
    // empty message first just to get the public key, OR we expose a separate
    // `getPublicKey` method.  For simplicity, sign a zero-length byte array
    // to retrieve the key, then discard that "signature".
    //
    // Real Seed Vault integration would expose a dedicated `publicKey` getter.
    // Here we sign a minimal probe to read the key.
    final probe = await _signer.sign(Uint8List(0));
    final publicKey = probe.publicKey;

    final challengeResponse = await _api.post('/auth/sws/challenge', {
      'public_key': publicKey,
    });
    final nonce = challengeResponse['nonce'] as String;
    final issuedAt = challengeResponse['issued_at'] as String;

    // Step 2: build the SIWS message.
    final message = _buildSiwsMessage(
      publicKey: publicKey,
      nonce: nonce,
      issuedAt: issuedAt,
    );

    // Step 3: sign the message.
    final signed = await _signer.sign(
      Uint8List.fromList(utf8.encode(message)),
    );

    // Step 4: submit to the backend.
    final tokenResponse = await _api.post('/auth/sws', {
      'public_key': signed.publicKey,
      'signature': base64.encode(signed.signature),
      'nonce': nonce,
    });

    final accessToken = tokenResponse['access_token'] as String?;
    final refreshToken = tokenResponse['refresh_token'] as String?;
    if (accessToken == null || refreshToken == null) {
      throw StateError('Server response missing tokens from /auth/sws');
    }

    // Step 5: persist tokens (so the 401-retry path works).
    await _authService.saveTokens(accessToken, refreshToken);

    final userId = extractUserIdFromJwt(accessToken);
    if (userId == null) {
      await _authService.clearTokens();
      throw StateError('Server returned a token without a valid user ID.');
    }

    return AuthResult(
      accessToken: accessToken,
      refreshToken: refreshToken,
      userId: userId,
    );
  }

  @override
  Future<void> signOut(String refreshToken) => _authService.logout();

  @override
  Future<AuthResult?> restore() async {
    // SWS users use the same JWT + refresh token mechanism as password users.
    final stored = await _authService.getToken();
    if (stored != null) {
      final userId = extractUserIdFromJwt(stored);
      if (userId != null) {
        final refresh = await _authService.getRefreshToken() ?? '';
        return AuthResult(
          accessToken: stored,
          refreshToken: refresh,
          userId: userId,
        );
      }
    }

    final refreshed = await _authService.refreshSession();
    if (refreshed != null) {
      final userId = extractUserIdFromJwt(refreshed);
      if (userId != null) {
        final refresh = await _authService.getRefreshToken() ?? '';
        return AuthResult(
          accessToken: refreshed,
          refreshToken: refresh,
          userId: userId,
        );
      }
    }

    return null;
  }
}

