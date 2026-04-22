import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/auth_provider.dart';
import '../../services/migration_service.dart';
import '../../screens/auth/auth_helpers.dart';
import 'password_login_form.dart';

/// Login widget for email + password auth.
///
/// Owns its own loading/error state and the conflict-resolution dialog,
/// mirroring the pattern of [SwsLoginWidget] for SWS auth.
class PasswordLoginWidget extends ConsumerStatefulWidget {
  const PasswordLoginWidget({super.key});

  @override
  ConsumerState<PasswordLoginWidget> createState() =>
      _PasswordLoginWidgetState();
}

class _PasswordLoginWidgetState extends ConsumerState<PasswordLoginWidget> {
  bool _isLoading = false;
  String? _errorMessage;

  Future<ConflictResolution> _showConflictDialog() async {
    final result = await showDialog<ConflictResolution>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Data conflict'),
        content: const Text(
          'You have local data on this device and your account already has '
          'data on the server. What would you like to do?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, ConflictResolution.keepLocal),
            child: const Text('Keep local data'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ConflictResolution.keepServer),
            child: const Text('Keep synced data'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ConflictResolution.merge),
            child: const Text('Merge both'),
          ),
        ],
      ),
    );
    return result ?? ConflictResolution.merge;
  }

  Future<void> _submit(String email, String password) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await ref.read(authTokenProvider.notifier).login(
            {'email': email, 'password': password},
            onConflict: _showConflictDialog,
          );
      if (!mounted) return;
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/inbox');
      }
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = authMessageFromDio(e);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Something went wrong. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PasswordLoginForm(
      onSubmit: _submit,
      isLoading: _isLoading,
      errorMessage: _errorMessage,
    );
  }
}
