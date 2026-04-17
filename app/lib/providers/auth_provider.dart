import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/auth_service.dart';

// ---------------------------------------------------------------------------
// Router refresh notifier
// ---------------------------------------------------------------------------

/// Flips whenever auth state changes so GoRouter re-evaluates its redirect.
///
/// Must be initialised before [runApp] via [initAuthState].
final authStateNotifier = ValueNotifier<bool>(false);

// ---------------------------------------------------------------------------
// Current user ID
// ---------------------------------------------------------------------------

/// The ID of the authenticated user.
///
/// Defaults to `'local'` (the pre-auth placeholder) and is updated to the
/// real user ID when [AuthNotifier] completes its build or after login.
final currentUserIdProvider =
    NotifierProvider<CurrentUserIdNotifier, String>(CurrentUserIdNotifier.new);

class CurrentUserIdNotifier extends Notifier<String> {
  @override
  String build() => 'local';
}

// ---------------------------------------------------------------------------
// Auth token provider
// ---------------------------------------------------------------------------

final authTokenProvider = AsyncNotifierProvider<AuthNotifier, String?>(
  AuthNotifier.new,
);

class AuthNotifier extends AsyncNotifier<String?> {
  @override
  Future<String?> build() async {
    final service = ref.watch(authServiceProvider);
    final token = await service.getToken();
    if (token != null) {
      final userId = _extractUserId(token) ?? 'local';
      ref.read(currentUserIdProvider.notifier).state = userId;
      authStateNotifier.value = true;
    }
    return token;
  }

  Future<void> login(String email, String password) async {
    state = const AsyncLoading();
    try {
      final service = ref.read(authServiceProvider);
      final token = await service.login(email, password);
      final userId = _extractUserId(token) ?? 'local';
      ref.read(currentUserIdProvider.notifier).state = userId;
      authStateNotifier.value = true;
      state = AsyncData(token);
    } catch (e, st) {
      state = AsyncError(e, st);
      rethrow;
    }
  }

  Future<void> register(String email, String password) async {
    state = const AsyncLoading();
    try {
      final service = ref.read(authServiceProvider);
      final token = await service.register(email, password);
      final userId = _extractUserId(token) ?? 'local';
      ref.read(currentUserIdProvider.notifier).state = userId;
      authStateNotifier.value = true;
      state = AsyncData(token);
    } catch (e, st) {
      state = AsyncError(e, st);
      rethrow;
    }
  }

  Future<void> logout() async {
    await ref.read(authServiceProvider).clearToken();
    ref.read(currentUserIdProvider.notifier).state = 'local';
    state = const AsyncData(null);
    authStateNotifier.value = false;
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
    return json['sub'] as String?;
  } catch (_) {
    return null;
  }
}
