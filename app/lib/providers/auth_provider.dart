import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/auth_service.dart';
import '../services/migration_service.dart';

// ---------------------------------------------------------------------------
// Router refresh notifier
// ---------------------------------------------------------------------------

/// Flips whenever auth state changes so GoRouter re-evaluates its redirect.
final authStateNotifier = ValueNotifier<bool>(false);

// ---------------------------------------------------------------------------
// Current user ID
// ---------------------------------------------------------------------------

/// The ID of the authenticated user.
///
/// Defaults to `'local'` (the pre-auth placeholder) and is updated to the
/// real user ID when [AuthNotifier] completes its build or after login.
/// [powerSyncInstanceProvider] listens to this to drive sync lifecycle.
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
  /// 1. If the stored access token is still valid → use it.
  /// 2. If it is expired (or absent) → try a silent refresh via the stored
  ///    refresh token.
  /// 3. If the refresh also fails → remain in local-only mode; never redirect
  ///    to the login screen.
  @override
  Future<String?> build() async {
    final service = ref.watch(authServiceProvider);
    final storedToken = await service.getToken();

    // Case 1: valid access token already in storage.
    if (storedToken != null) {
      final userId = _extractUserId(storedToken);
      if (userId != null) {
        ref.read(currentUserIdProvider.notifier).setUserId(userId);
        authStateNotifier.value = true;
        return storedToken;
      }
    }

    // Case 2: access token missing or expired — try silent refresh.
    final refreshed = await service.refreshSession();
    if (refreshed != null) {
      final userId = _extractUserId(refreshed);
      if (userId != null) {
        ref.read(currentUserIdProvider.notifier).setUserId(userId);
        authStateNotifier.value = true;
        return refreshed;
      }
    }

    // Case 3: no valid session — stay in local-only mode.
    try {
      await service.clearTokens();
    } catch (_) {}
    ref.read(currentUserIdProvider.notifier).reset();
    authStateNotifier.value = false;
    return null;
  }

  /// Sign in and optionally migrate local data to the authenticated account.
  ///
  /// [onConflict] is called when the local device has data AND the server
  /// already has data for this user.  The callback should show a dialog and
  /// return the user's resolution choice.  If null the default is [merge].
  Future<void> login(
    String email,
    String password, {
    Future<ConflictResolution> Function()? onConflict,
  }) async {
    state = const AsyncLoading();
    try {
      final service = ref.read(authServiceProvider);
      final (:accessToken, refreshToken: _) =
          await service.login(email, password);
      final userId = _extractUserId(accessToken);
      if (userId == null) {
        await service.clearTokens();
        throw StateError('Server returned a token without a valid user ID.');
      }
      await _handleMigration(userId, onConflict: onConflict);
      ref.read(currentUserIdProvider.notifier).setUserId(userId);
      authStateNotifier.value = true;
      state = AsyncData(accessToken);
    } catch (e, st) {
      state = AsyncError(e, st);
      rethrow;
    }
  }

  /// Register a new account and migrate local data to the new user.
  Future<void> register(
    String email,
    String password, {
    Future<ConflictResolution> Function()? onConflict,
  }) async {
    state = const AsyncLoading();
    try {
      final service = ref.read(authServiceProvider);
      final (:accessToken, refreshToken: _) =
          await service.register(email, password);
      final userId = _extractUserId(accessToken);
      if (userId == null) {
        await service.clearTokens();
        throw StateError('Server returned a token without a valid user ID.');
      }
      // New registrations have no server-side data yet; skip conflict check.
      await _handleMigration(userId, skipConflictCheck: true);
      ref.read(currentUserIdProvider.notifier).setUserId(userId);
      authStateNotifier.value = true;
      state = AsyncData(accessToken);
    } catch (e, st) {
      state = AsyncError(e, st);
      rethrow;
    }
  }

  Future<void> logout() async {
    // Reassign rows owned by the authenticated user back to the `'local'`
    // placeholder before resetting the user id.  Without this, queries —
    // which filter by [currentUserIdProvider] — would match nothing after
    // sign-out and the user's tasks/tags appear to vanish.  Signing in
    // again runs the mirror migration in [_handleMigration], so data
    // round-trips correctly through a logout/login cycle.
    final previousUserId = ref.read(currentUserIdProvider);
    if (previousUserId != 'local') {
      try {
        await ref.read(migrationServiceProvider).migrate(
              fromUserId: previousUserId,
              toUserId: 'local',
            );
      } catch (_) {
        // Best-effort: if the local reassignment fails the rows stay
        // under the old user id and will be recovered when the same
        // user signs in again.  Don't block sign-out on it.
      }
    }

    try {
      await ref.read(authServiceProvider).logout();
    } catch (_) {
      // Best-effort; proceed with local state reset regardless.
    }
    ref.read(currentUserIdProvider.notifier).reset();
    state = const AsyncData(null);
    authStateNotifier.value = false;
  }

  // ---------------------------------------------------------------------------
  // Migration helper
  // ---------------------------------------------------------------------------

  Future<void> _handleMigration(
    String toUserId, {
    Future<ConflictResolution> Function()? onConflict,
    bool skipConflictCheck = false,
  }) async {
    final migrationService = ref.read(migrationServiceProvider);
    final hasLocal = await migrationService.hasLocalData();
    if (!hasLocal) return; // Nothing to migrate.

    ConflictResolution resolution = ConflictResolution.merge;

    if (!skipConflictCheck) {
      // Treat remote-check failures as "possibly has data" so the user still
      // gets a chance to resolve a conflict instead of silently merging.
      bool serverHasData;
      try {
        serverHasData = await ref.read(authServiceProvider).serverHasTodos();
      } catch (_) {
        serverHasData = true;
      }
      if (serverHasData && onConflict != null) {
        resolution = await onConflict();
      }
    }

    switch (resolution) {
      case ConflictResolution.keepLocal:
        await migrationService.migrate(fromUserId: 'local', toUserId: toUserId);
      case ConflictResolution.keepServer:
        await migrationService.deleteLocalData('local');
      case ConflictResolution.merge:
        await migrationService.migrate(fromUserId: 'local', toUserId: toUserId);
    }
  }
}

// ---------------------------------------------------------------------------
// JWT helpers
// ---------------------------------------------------------------------------

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
