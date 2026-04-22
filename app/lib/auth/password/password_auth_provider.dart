import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/auth_service.dart';
import '../auth_provider_interface.dart';
import '../jwt_utils.dart';
import 'password_login_widget.dart';

/// [AuthProvider] implementation for the classic email + password flow.
///
/// Delegates all token I/O to [AuthService] so the JWT lifecycle
/// (storage, 401-retry wiring) remains in a single place.
class PasswordAuthProvider implements AuthProvider {
  const PasswordAuthProvider(this._ref);

  final Ref _ref;

  AuthService get _service => _ref.read(authServiceProvider);

  @override
  Widget buildLoginWidget(BuildContext context) => const PasswordLoginWidget();

  @override
  Future<AuthResult> signIn(Map<String, dynamic> params) async {
    final email = params['email'] as String;
    final password = params['password'] as String;
    final (:accessToken, :refreshToken) = await _service.login(email, password);
    final userId = extractUserIdFromJwt(accessToken);
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
      final userId = extractUserIdFromJwt(stored);
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
      final userId = extractUserIdFromJwt(refreshed);
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

