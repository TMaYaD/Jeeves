import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/auth_provider.dart';
import '../../screens/auth/auth_helpers.dart';
import 'password_login_form.dart';

/// Login widget for email + password auth.
///
/// Owns its own loading/error state, mirroring the pattern of [SwsLoginWidget]
/// for SWS auth.
class PasswordLoginWidget extends ConsumerStatefulWidget {
  const PasswordLoginWidget({super.key});

  @override
  ConsumerState<PasswordLoginWidget> createState() =>
      _PasswordLoginWidgetState();
}

class _PasswordLoginWidgetState extends ConsumerState<PasswordLoginWidget> {
  bool _isLoading = false;
  String? _errorMessage;

  Future<void> _submit(String email, String password) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await ref
          .read(authTokenProvider.notifier)
          .login({'email': email, 'password': password});
      if (!mounted) return;
      // Always the app, never a pop back to the caller: a finished sign-in must
      // not leave the screen that pushed this one sitting underneath it. The
      // app is the destination whatever the store says about enrolment —
      // setting sync up is offered in Settings, not imposed here (#673).
      context.go('/inbox');
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
