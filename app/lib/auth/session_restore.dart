/// What a cold start found in secure storage, and what may be done about it.
///
/// Both JWT-bearing providers share [restoreJwtSession] rather than keeping a
/// copy each. Their bodies used to be near-identical thirty-line duplicates, and
/// #606 was a bug in that shape: a fix applied to one of them would have left the
/// other still destroying an enrolled device's credentials on an offline
/// relaunch. One implementation is what stops them drifting apart again.
library;

import '../services/auth_service.dart';
import 'auth_provider_interface.dart';
import 'jwt_utils.dart';

/// The three answers a session restore can give.
///
/// The distinction that matters is between "there is no session" and "I could not
/// find out" — see ADR-0041. Only [SessionAbsent] may clear credentials.
sealed class SessionRestoreOutcome {
  const SessionRestoreOutcome();
}

/// A usable access token: stored and unexpired, or silently refreshed.
final class SessionRestored extends SessionRestoreOutcome {
  const SessionRestored(this.session);

  final AuthResult session;
}

/// Credentials are on this device and were **not** authoritatively rejected —
/// the server could not be reached, or answered something that is not a
/// corroborated 401.
///
/// The device stays signed in as [userId] and keeps authoring; both credentials
/// are retained for the next attempt. [expiredAccessToken] is what
/// `AuthService.getToken()` has already set on the Dio, so the first request
/// after the network returns 401s into the retry interceptor and the session
/// self-heals.
final class SessionUnverified extends SessionRestoreOutcome {
  const SessionUnverified({
    required this.userId,
    required this.expiredAccessToken,
  });

  final String userId;
  final String expiredAccessToken;
}

/// Nothing stored, or the server authoritatively rejected what was.
///
/// The only outcome that clears credentials.
final class SessionAbsent extends SessionRestoreOutcome {
  const SessionAbsent();
}

/// Restore a JWT session from [service]'s storage, without ever guessing.
///
/// A stored access token that parses unexpired is the session. Otherwise the
/// silent refresh decides, and its four outcomes map straight onto the three
/// answers above: refreshed → [SessionRestored]; rejected or nothing-stored →
/// [SessionAbsent]; inconclusive → [SessionUnverified], as long as the stored
/// access token still yields a `sub`.
///
/// An inconclusive refresh with **no recoverable account id** — a torn secure
/// store holding a refresh token but no parseable access token — is
/// [SessionAbsent] by decision, not oversight: there is no id to stay signed in
/// as. Recovering it from the pinned enrolment identity (`RootPins.userId`) is
/// deferred to #639; a test pins today's residual so a change to it is
/// deliberate.
Future<SessionRestoreOutcome> restoreJwtSession(AuthService service) async {
  final stored = await service.getToken();
  if (stored != null) {
    final userId = extractUserIdFromJwt(stored);
    if (userId != null) {
      return SessionRestored(
        await _sessionWithStoredRefreshToken(service, stored, userId),
      );
    }
  }

  switch (await service.refreshSession()) {
    case SessionRefreshed(:final accessToken):
      final userId = extractUserIdFromJwt(accessToken);
      // A token the server just minted but that carries no `sub` is a broken
      // server, not a session — and unlike a network failure it is authoritative
      // about what this device now holds.
      if (userId == null) return const SessionAbsent();
      return SessionRestored(
        await _sessionWithStoredRefreshToken(service, accessToken, userId),
      );

    case SessionRefreshRejected():
    case SessionRefreshTokenAbsent():
      return const SessionAbsent();

    case SessionRefreshInconclusive():
      final userId =
          stored == null ? null : extractUserIdFromJwt(stored, allowExpired: true);
      if (userId == null) return const SessionAbsent();
      return SessionUnverified(userId: userId, expiredAccessToken: stored!);
  }
}

/// The session for [accessToken], carrying whatever refresh token is in storage.
Future<AuthResult> _sessionWithStoredRefreshToken(
  AuthService service,
  String accessToken,
  String userId,
) async =>
    AuthResult(
      accessToken: accessToken,
      refreshToken: await service.getRefreshToken() ?? '',
      userId: userId,
    );
