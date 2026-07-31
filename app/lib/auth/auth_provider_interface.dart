import 'package:flutter/widgets.dart';

import 'session_restore.dart';

/// Common interface that every authentication backend must implement.
///
/// Concrete implementations are selected at compile time via
/// `--dart-define=JEEVES_AUTH_MODE=<mode>` (see `auth_mode.dart`).
abstract interface class AuthProvider {
  /// Returns a widget that lets the user initiate sign-in.
  ///
  /// The widget is responsible for collecting credentials and triggering
  /// [signIn].  Navigation after a successful sign-in is handled by
  /// [LoginScreen], not the widget.
  Widget buildLoginWidget(BuildContext context);

  /// Perform sign-in with the given [params].
  ///
  /// The shape of [params] depends on the concrete provider:
  /// - password: `{'email': ..., 'password': ...}`
  /// - sws: `{}` (the provider handles wallet interaction internally)
  Future<AuthResult> signIn(Map<String, dynamic> params);

  /// Revoke the server-side session identified by [refreshToken].
  Future<void> signOut(String refreshToken);

  /// Attempt to restore an existing session from secure storage.
  ///
  /// Three answers, not two: a session, no session, or *credentials that could
  /// not be verified* — the server was unreachable, or answered something that is
  /// not a corroborated 401. Only [SessionAbsent] means the user must sign in
  /// again; [SessionUnverified] keeps the device signed in and authoring, because
  /// clearing credentials on an inconclusive answer destroys an enrolled device's
  /// enrolment and drops the whole session's ops (ADR-0041).
  Future<SessionRestoreOutcome> restore();
}

/// Canonical authentication result returned by every [AuthProvider].
///
/// Each provider decodes the JWT `sub` claim to populate [userId], so
/// [AuthNotifier] does not need to inspect the token itself.
class AuthResult {
  const AuthResult({
    required this.accessToken,
    required this.refreshToken,
    required this.userId,
  });

  final String accessToken;
  final String refreshToken;
  final String userId;
}
