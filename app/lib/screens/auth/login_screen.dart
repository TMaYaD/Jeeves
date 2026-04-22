import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../auth/auth_mode.dart';
import '../../auth/password/password_auth_provider.dart';
import '../../providers/auth_provider.dart';
import '../../services/migration_service.dart';
import '../../widgets/jeeves_logo.dart';
import 'auth_helpers.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  bool _isLoading = false;
  String? _errorMessage;

  Future<ConflictResolution> _showConflictDialog() async {
    final result = await showDialog<ConflictResolution>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Data conflict'),
        content: const Text(
          'You have local data on this device and your account already has data on the server. What would you like to do?',
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

  Widget _buildLoginWidget() {
    final provider = ref.read(authImplProvider);
    if (provider is PasswordAuthProvider) {
      return provider.buildForm(
        onSubmit: _submit,
        isLoading: _isLoading,
        errorMessage: _errorMessage,
      );
    }
    // For SWS (and any future providers), delegate entirely to the provider
    // widget — conflict resolution is handled inside the notifier.
    return provider.buildLoginWidget(context);
  }

  @override
  Widget build(BuildContext context) {
    final canPop = context.canPop();
    return Scaffold(
      appBar: canPop
          ? AppBar(
              backgroundColor: Colors.white,
              elevation: 0,
              leading: CloseButton(onPressed: () => context.pop()),
            )
          : null,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: JeevesLogo(
                      variant: JeevesLogoVariant.wordmark,
                      size: 48,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Sign in to sync across devices',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, color: Color(0xFF6B7280)),
                  ),
                  const SizedBox(height: 40),
                  _buildLoginWidget(),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: _isLoading
                        ? null
                        : () => context.pushReplacement('/register'),
                    child: const Text("Don't have an account? Create one"),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
