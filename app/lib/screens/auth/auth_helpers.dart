import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

String authMessageFromDio(DioException e, {int? duplicateStatusCode}) {
  final status = e.response?.statusCode;
  if (status == 401) return 'Invalid email or password.';
  if (duplicateStatusCode != null && status == duplicateStatusCode) {
    return 'An account with this email already exists.';
  }
  if (e.type == DioExceptionType.connectionError ||
      e.type == DioExceptionType.connectionTimeout) {
    return 'Connection failed. Check your network.';
  }
  return 'Something went wrong. Please try again.';
}

Widget buildErrorBanner(String message) => Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFCA5A5)),
      ),
      child: Text(
        message,
        style: const TextStyle(color: Color(0xFFDC2626), fontSize: 14),
      ),
    );
