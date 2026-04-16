// REST API service — wraps the FastAPI backend.
//
// Handles authentication, task CRUD for non-sync paths (e.g. initial load,
// conflict resolution), AI requests, and settings.

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'platform_helper.dart'
    if (dart.library.io) 'platform_helper_io.dart';

class ApiService {
  ApiService({required String baseUrl})
      : _baseUrl = baseUrl,
        _dio = Dio(BaseOptions(baseUrl: baseUrl)) {
    _dio.interceptors.add(_AuthRetryInterceptor(this));
  }

  final String _baseUrl;
  final Dio _dio;

  String get baseUrl => _baseUrl;

  String? _authToken;

  // Called by AuthService after construction to wire up the 401 refresh path.
  // Avoids a circular provider dependency (ApiService ↔ AuthService).
  Future<String?> Function()? _onUnauthorized;

  // De-duplicates concurrent 401-triggered refreshes.  The backend rotates
  // (revokes) the refresh token on each use, so without this guard two
  // simultaneous refreshes would race — one wins, the other gets 401 and
  // fails the retrying request.  All callers share a single in-flight future.
  Future<String?>? _refreshInFlight;

  void setOnUnauthorized(Future<String?> Function() callback) {
    _onUnauthorized = callback;
  }

  void setAuthToken(String token) {
    _authToken = token;
    _dio.options.headers['Authorization'] = 'Bearer $token';
  }

  void clearAuthToken() {
    _authToken = null;
    _dio.options.headers.remove('Authorization');
  }

  bool get isAuthenticated => _authToken != null;

  Map<String, String> get authHeaders => _authToken != null
      ? {'Authorization': 'Bearer $_authToken'}
      : {};

  Future<Map<String, dynamic>> postFormData(
    String path,
    FormData formData,
  ) async {
    final response = await _dio.post<Map<String, dynamic>>(path, data: formData);
    return response.data!;
  }

  Future<Map<String, dynamic>> get(String path) async {
    final response = await _dio.get<Map<String, dynamic>>(path);
    return response.data!;
  }

  /// Like [get] but returns a list — used where the endpoint returns a JSON array.
  Future<List<dynamic>> getList(String path) async {
    final response = await _dio.get<List<dynamic>>(path);
    return response.data ?? [];
  }

  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response =
        await _dio.post<Map<String, dynamic>>(path, data: body);
    return response.data!;
  }

  Future<Map<String, dynamic>> patch(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response =
        await _dio.patch<Map<String, dynamic>>(path, data: body);
    return response.data!;
  }

  Future<void> delete(String path, {Map<String, dynamic>? body}) async {
    await _dio.delete<void>(path, data: body);
  }
}

/// Intercepts 401 responses, attempts a silent token refresh, and retries
/// the original request once.  If the refresh also fails the error is
/// propagated normally.
class _AuthRetryInterceptor extends Interceptor {
  _AuthRetryInterceptor(this._api);
  final ApiService _api;

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final response = err.response;
    final onUnauthorized = _api._onUnauthorized;

    if (response?.statusCode == 401 &&
        onUnauthorized != null &&
        // Avoid infinite loops on the refresh endpoint itself.
        !(response?.requestOptions.path.endsWith('/session/refresh') ?? false)) {
      try {
        // Share a single refresh across concurrent 401s to avoid racing the
        // server-side refresh-token rotation.
        Future<String?> refreshFuture = _api._refreshInFlight ??
            (() {
              final f = onUnauthorized();
              _api._refreshInFlight = f;
              f.whenComplete(() {
                if (identical(_api._refreshInFlight, f)) {
                  _api._refreshInFlight = null;
                }
              });
              return f;
            })();
        final newToken = await refreshFuture;
        if (newToken != null) {
          // Retry original request with the new token.
          final opts = err.requestOptions;
          opts.headers['Authorization'] = 'Bearer $newToken';
          final retried = await _api._dio.fetch<dynamic>(opts);
          handler.resolve(retried);
          return;
        }
      } catch (_) {
        // Refresh failed — fall through to propagate the original 401.
      }
    }
    handler.next(err);
  }
}

String _defaultBaseUrl() {
  const override = String.fromEnvironment('JEEVES_API_URL');
  if (override.isNotEmpty) return override;

  // Android emulator routes 10.0.2.2 to the host machine's loopback.
  final host =
      !kIsWeb && isAndroidPlatform ? '10.0.2.2' : 'localhost';
  return 'http://$host:8000';
}

final apiServiceProvider = Provider<ApiService>((ref) {
  return ApiService(baseUrl: _defaultBaseUrl());
});
