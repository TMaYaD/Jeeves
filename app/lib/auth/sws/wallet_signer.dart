import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Abstraction over a Solana wallet that can sign arbitrary messages.
abstract interface class WalletSigner {
  /// Returns the wallet's public key as a base58-encoded string.
  Future<String> getPublicKey();

  /// Signs [message] and returns the signer's public key (base58) and the
  /// ed25519 signature over the raw bytes.
  Future<({String publicKey, Uint8List signature})> sign(Uint8List message);
}

/// Stub signer used in unit tests.  Returns a deterministic but invalid
/// signature (all zeros) so the backend stub can accept it without doing
/// real ed25519 verification.
class StubWalletSigner implements WalletSigner {
  const StubWalletSigner({
    required this.publicKey,
  });

  final String publicKey;

  @override
  Future<String> getPublicKey() async => publicKey;

  @override
  Future<({String publicKey, Uint8List signature})> sign(
    Uint8List message,
  ) async {
    return (
      publicKey: publicKey,
      signature: Uint8List(64), // 64 zero bytes — accepted by the test stub
    );
  }
}

/// Mobile Wallet Adapter signer — works with any MWA-compatible Solana wallet
/// app installed on the device (e.g. Phantom, Solflare).
///
/// Communicates with the Android-side `MwaPlugin` via a [MethodChannel].
/// The plugin uses the MWA clientlib-ktx SDK
/// (`com.solanamobile:mobile-wallet-adapter-clientlib-ktx`) to open a local
/// association with the wallet, authorise the app, and request message signing.
///
/// Both [getPublicKey] and [sign] open an MWA session, so the wallet's
/// authorisation prompt is shown on each call. A future improvement would cache
/// the auth token across calls within a single sign-in attempt.
class MobileWalletAdapterSigner implements WalletSigner {
  const MobileWalletAdapterSigner();

  static const _channel = MethodChannel('jeeves/mwa');

  @override
  Future<String> getPublicKey() async {
    try {
      final result = await _channel.invokeMethod<String>('getPublicKey');
      if (result == null) throw StateError('MWA: wallet returned no public key');
      return result;
    } on PlatformException catch (e) {
      throw StateError('Wallet error: ${e.message}');
    }
  }

  @override
  Future<({String publicKey, Uint8List signature})> sign(Uint8List message) async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('sign', {
        'message': base64.encode(message),
      });
      if (result == null) throw StateError('MWA: wallet returned no result');
      return (
        publicKey: result['publicKey'] as String,
        signature: base64.decode(result['signature'] as String),
      );
    } on PlatformException catch (e) {
      throw StateError('Wallet error: ${e.message}');
    }
  }
}

/// Placeholder for the Seed Vault integration required by Solana Seeker.
///
/// The actual implementation needs the `seedvault_wallet` package, which is
/// distributed as part of the Solana Mobile Stack SDK and is not available on
/// pub.dev.  Replace this class with a real implementation once the SDK is
/// available in the project:
///
/// ```yaml
/// # pubspec.yaml
/// dependencies:
///   seedvault_wallet:
///     path: ../solana-mobile-stack/seedvault_wallet
/// ```
class SeedVaultSigner implements WalletSigner {
  const SeedVaultSigner();

  @override
  Future<String> getPublicKey() async {
    throw UnsupportedError(
      'SWS mode is not functional yet: SeedVaultSigner requires the Solana '
      'Mobile Stack SDK (seedvault_wallet), which is not yet available on '
      'pub.dev. See the class-level doc comment for integration instructions.',
    );
  }

  @override
  Future<({String publicKey, Uint8List signature})> sign(
    Uint8List message,
  ) async {
    throw UnsupportedError(
      'SWS mode is not functional yet: SeedVaultSigner requires the Solana '
      'Mobile Stack SDK (seedvault_wallet), which is not yet available on '
      'pub.dev. See the class-level doc comment for integration instructions.',
    );
  }
}
