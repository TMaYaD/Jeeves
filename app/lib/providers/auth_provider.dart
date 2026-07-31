import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_mode.dart';
import '../auth/jwt_utils.dart';
import '../auth/session_gate.dart';
import '../auth/session_restore.dart';
import '../services/auth_service.dart';
import '../sync/enrolment_state.dart';
import 'sync_stack_provider.dart';

// ---------------------------------------------------------------------------
// Current user ID
// ---------------------------------------------------------------------------

/// The ID of the authenticated user.
///
/// Defaults to `'local'` (the pre-auth placeholder) and is updated to the
/// real user ID when [AuthNotifier] completes its build or after login.
/// `syncStackProvider` and `syncLifecycleProvider` both watch it: the Workspace
/// ids, the escrow slot and the Grants are all derived from the account.
final currentUserIdProvider =
    NotifierProvider<CurrentUserIdNotifier, String>(CurrentUserIdNotifier.new);

class CurrentUserIdNotifier extends Notifier<String> {
  @override
  String build() => 'local';

  void setUserId(String id) => state = id;

  void reset() => state = 'local';
}

// ---------------------------------------------------------------------------
// Auth token provider
// ---------------------------------------------------------------------------

final authTokenProvider = AsyncNotifierProvider<AuthNotifier, String?>(
  AuthNotifier.new,
);

class AuthNotifier extends AsyncNotifier<String?> {
  /// Cold-start: restore session from stored tokens.
  ///
  /// Delegates to the active [AuthProvider] so the restore logic is
  /// provider-specific (password vs SWS both use JWTs but differ in how
  /// the token was originally obtained).
  ///
  /// **[clearTokens] is reachable from exactly one arm, [SessionAbsent].** That
  /// is the #606 fix stated as a shape rather than a condition: every failure
  /// that is not the server saying "no" lands in [SessionUnverified] and costs
  /// the device nothing. Destroying credentials here is not a sign-out prompt —
  /// `currentUserIdProvider` is what the whole sync spine hangs off, so it also
  /// refuses the stack, settles the capture seam silent, and (with the
  /// initial-upload marker already set) drops every write of the session with no
  /// path left to re-carry them.
  @override
  Future<String?> build() async {
    final provider = ref.watch(authImplProvider);

    switch (await provider.restore()) {
      case SessionRestored(:final session):
        ref.read(currentUserIdProvider.notifier).setUserId(session.userId);
        sessionGateNotifier.value = await _enrolmentGate();
        return session.accessToken;

      case SessionUnverified(:final userId, :final expiredAccessToken):
        // Signed in as the account the stored token names, on credentials of
        // unknown validity. The id is set *before* the gate is asked, because
        // `_enrolmentGate()` reads `syncStackProvider` and that provider refuses
        // the `'local'` placeholder — the same ordering the restored arm relies
        // on. The expired token is returned rather than null so this provider's
        // value matches the `Authorization` header `getToken()` has already set,
        // and the first request once the network returns self-heals through the
        // retry interceptor.
        ref.read(currentUserIdProvider.notifier).setUserId(userId);
        sessionGateNotifier.value = await _enrolmentGate();
        return expiredAccessToken;

      case SessionAbsent():
        // No session — stay in local-only mode.
        try {
          await ref.read(authServiceProvider).clearTokens();
        } catch (_) {}
        ref.read(currentUserIdProvider.notifier).reset();
        sessionGateNotifier.value = SessionGate.signedOut;
        return null;
    }
  }

  /// Sign in.
  ///
  /// [params] shape depends on the active [AuthProvider]:
  /// - password mode: `{'email': ..., 'password': ...}`
  /// - sws mode: `{}` (the provider handles wallet interaction internally)
  ///
  /// There is no local→server data migration and therefore no conflict to
  /// resolve: the store is the device's own, the op log is what converges it
  /// with the account's other devices, and the initial upload authors it under
  /// the identity enrolment mints.
  Future<void> login(Map<String, dynamic> params) async {
    state = const AsyncLoading();
    try {
      final provider = ref.read(authImplProvider);
      final result = await provider.signIn(params);
      ref.read(currentUserIdProvider.notifier).setUserId(result.userId);
      sessionGateNotifier.value = await _enrolmentGate();
      state = AsyncData(result.accessToken);
    } catch (e, st) {
      state = AsyncError(e, st);
      rethrow;
    }
  }

  /// Register a new account.
  ///
  /// Registration is still handled directly by [AuthService] because it is
  /// password-only — SWS users are upserted on first login.
  Future<void> register(String email, String password) async {
    state = const AsyncLoading();
    try {
      final service = ref.read(authServiceProvider);
      final (:accessToken, refreshToken: _) =
          await service.register(email, password);
      final userId = extractUserIdFromJwt(accessToken);
      if (userId == null) {
        await service.clearTokens();
        throw StateError('Server returned a token without a valid user ID.');
      }
      ref.read(currentUserIdProvider.notifier).setUserId(userId);
      sessionGateNotifier.value = await _enrolmentGate();
      state = AsyncData(accessToken);
    } catch (e, st) {
      state = AsyncError(e, st);
      rethrow;
    }
  }

  /// Sign out: tell the server, drop the tokens, and go back to local-only.
  ///
  /// **No local data is touched.** The row-reassignment sweep this used to run
  /// existed because sign-in migrated the local store into the account; nothing
  /// filters domain reads by user id, and the op log carries the identity, so
  /// there is nothing left for a sign-out to fix up.
  Future<void> logout() async {
    try {
      final refreshToken =
          await ref.read(authServiceProvider).getRefreshToken() ?? '';
      await ref.read(authImplProvider).signOut(refreshToken);
    } catch (_) {
      // Best-effort; proceed with local state reset regardless.
    }
    ref.read(currentUserIdProvider.notifier).reset();
    state = const AsyncData(null);
    sessionGateNotifier.value = SessionGate.signedOut;
  }

  /// Where a signed-in device belongs: the app, or onboarding.
  ///
  /// Read from this device's own store, with **no network** — a device that has
  /// never enrolled holds no member credential to ask with, and the answer has
  /// to be the same offline.
  ///
  /// **Fails open to [SessionGate.ready].** A store that cannot be read is a bug
  /// to fix, not a reason to lock somebody out of an app that works offline; the
  /// worst case is a device that is not syncing and does not say so on this
  /// surface, which the drawer indicator still reports honestly.
  Future<SessionGate> _enrolmentGate() async {
    try {
      final stack = await ref.read(syncStackProvider.future);
      return (await stack.readEnrolmentStatus()).state ==
              EnrolmentState.enrolled
          ? SessionGate.ready
          : SessionGate.needsEnrolment;
    } catch (_) {
      return SessionGate.ready;
    }
  }
}
