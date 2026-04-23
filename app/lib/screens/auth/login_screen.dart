import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../auth/auth_mode.dart';
import '../../widgets/jeeves_logo.dart';

class LoginScreen extends ConsumerWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canPop = context.canPop();
    final provider = ref.read(authImplProvider);
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
                  provider.buildLoginWidget(context),
                  if (!isSwsMode) ...[
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () => context.pushReplacement('/register'),
                      child: const Text("Don't have an account? Create one"),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
