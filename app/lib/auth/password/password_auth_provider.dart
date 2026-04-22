import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/auth_service.dart';
import '../auth_provider_interface.dart';
import 'password_login_form.dart';

/// [AuthProvider] implementation for the classic email + password flow.
///
/// Delegates all token I/O to [AuthService] so the JWT lifecycle
/// (storage, 401-retry wiring) remains in a single place.
class PasswordAuthProvider implements AuthProvider {
  const PasswordAuthProvider(this._ref);

  final Ref _ref;

  AuthService get _service => _ref.read(authServiceProvider);

  @override
  Widget buildLoginWidget(BuildContext context) {
    // The widget is stateless here; LoginScreen passes its own callbacks.
    // The actual onSubmit and loading/error state are owned by LoginScreen.
    // This returns a thin wrapper that LoginScreen replaces with its own
    // stateful form built from PasswordLoginForm.
    //
    // LoginScreen calls buildLoginWidget and passes its _submit callback, so
    // it needs to hold a reference to the form builder.  We expose a factory
    // function via a public helper instead.
    throw UnimplementedError(
      'Use PasswordAuthProvider.buildForm() from LoginScreen instead.',
    );
  }

  /// Build the password form widget, wiring [onSubmit] from the caller.
  Widget buildForm({
    required Future<void> Function(String email, String password) onSubmit,
    bool isLoading = false,
    String? errorMessage,
  }) {
    return PasswordLoginForm(
      onSubmit: onSubmit,
      isLoading: isLoading,
      errorMessage: errorMessage,
    );
  }

  @override
  Future<AuthResult> signIn(Map<String, dynamic> params) async {
    final email = params['email'] as String;
    final password = params['password'] as String;
    final (:accessToken, :refreshToken) = await _service.login(email, password);
    final userId = _extractUserId(accessToken);
    if (userId == null) {
      await _service.clearTokens();
      throw StateError('Server returned a token without a valid user ID.');
    }
    return AuthResult(
      accessToken: accessToken,
      refreshToken: refreshToken,
      userId: userId,
    );
  }

  @override
  Future<void> signOut(String refreshToken) => _service.logout();

  @override
  Future<AuthResult?> restore() async {
    final stored = await _service.getToken();
    if (stored != null) {
      final userId = _extractUserId(stored);
      if (userId != null) {
        final refresh = await _service.getRefreshToken() ?? '';
        return AuthResult(
          accessToken: stored,
          refreshToken: refresh,
          userId: userId,
        );
      }
    }

    // Access token missing or expired — try silent refresh.
    final refreshed = await _service.refreshSession();
    if (refreshed != null) {
      final userId = _extractUserId(refreshed);
      if (userId != null) {
        final refresh = await _service.getRefreshToken() ?? '';
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

/// Decode a JWT and return the `sub` claim if the token is not expired.
String? _extractUserId(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = parts[1];
    final padded = payload.padRight(
      payload.length + (4 - payload.length % 4) % 4,
      '=',
    );
    final decoded = utf8.decode(base64Url.decode(padded));
    final json = jsonDecode(decoded) as Map<String, dynamic>;
    final exp = json['exp'];
    final expSeconds =
        exp is int ? exp : (exp is String ? int.tryParse(exp) : null);
    final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (expSeconds != null && expSeconds <= nowSeconds) return null;
    return json['sub'] as String?;
  } catch (_) {
    return null;
  }
}
