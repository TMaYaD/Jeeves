import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_provider_interface.dart';
import 'password/password_auth_provider.dart';
import 'sws/sws_auth_provider.dart';

/// Compile-time auth mode selection.
///
/// Pass `--dart-define=JEEVES_AUTH_MODE=sws` at build time to enable
/// Sign-In With Solana.  Defaults to the classic email + password flow.
const _authMode = String.fromEnvironment(
  'JEEVES_AUTH_MODE',
  defaultValue: 'password',
);

/// The active [AuthProvider] implementation, selected at compile time.
///
/// Override in tests:
/// ```dart
/// final container = ProviderContainer(overrides: [
///   authImplProvider.overrideWithValue(MockAuthProvider()),
/// ]);
/// ```
final authImplProvider = Provider<AuthProvider>((ref) {
  return switch (_authMode) {
    'sws' => SwsAuthProvider(ref),
    _ => PasswordAuthProvider(ref),
  };
});
