// REST API service — wraps the FastAPI backend.
//
// Handles authentication, task CRUD for non-sync paths (e.g. initial load,
// conflict resolution), AI requests, and settings.

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import 'platform_helper.dart'
    if (dart.library.io) 'platform_helper_io.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ApiService {
  ApiService({required String baseUrl})
      : _dio = Dio(BaseOptions(baseUrl: baseUrl));

  final Dio _dio;

  // Auth token — set after login.
  String? _authToken;

  void setAuthToken(String token) {
    _authToken = token;
    _dio.options.headers['Authorization'] = 'Bearer $token';
  }

  void clearAuthToken() {
    _authToken = null;
    _dio.options.headers.remove('Authorization');
  }

  bool get isAuthenticated => _authToken != null;

  Future<Map<String, dynamic>> get(String path) async {
    final response = await _dio.get<Map<String, dynamic>>(path);
    return response.data!;
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

  Future<void> delete(String path) async {
    await _dio.delete<void>(path);
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
