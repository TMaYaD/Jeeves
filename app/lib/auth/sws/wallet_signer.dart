import 'dart:typed_data';

/// Abstraction over a Solana wallet that can sign arbitrary messages.
abstract interface class WalletSigner {
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
  Future<({String publicKey, Uint8List signature})> sign(
    Uint8List message,
  ) async {
    return (
      publicKey: publicKey,
      signature: Uint8List(64), // 64 zero bytes — accepted by the test stub
    );
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
  Future<({String publicKey, Uint8List signature})> sign(
    Uint8List message,
  ) async {
    throw UnimplementedError(
      'SeedVaultSigner requires the Solana Mobile Stack SDK. '
      'See the class-level doc comment for integration instructions.',
    );
  }
}
