import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/auth_provider.dart';

/// Login widget for Sign-In With Solana.
///
/// Renders a single "Connect wallet" button.  On tap it calls
/// [authTokenProvider.notifier.login] with an empty params map — the
/// [SwsAuthProvider] handles all wallet interaction internally.
class SwsLoginWidget extends ConsumerStatefulWidget {
  const SwsLoginWidget({super.key});

  @override
  ConsumerState<SwsLoginWidget> createState() => _SwsLoginWidgetState();
}

class _SwsLoginWidgetState extends ConsumerState<SwsLoginWidget> {
  bool _isLoading = false;
  String? _errorMessage;

  Future<void> _connectWallet() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await ref
          .read(authTokenProvider.notifier)
          .login({}, onConflict: null);
      if (!mounted) return;
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/inbox');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // Show the underlying error text so we don't mask backend / wallet
        // failures behind a generic "could not connect" string. The user-
        // facing copy stays as the prefix; the detail comes from the throw.
        _errorMessage = 'Could not sign in with wallet: $e';
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_errorMessage != null) ...[
          Text(
            _errorMessage!,
            style: const TextStyle(color: Colors.red),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
        ],
        ElevatedButton(
          key: const Key('connect_wallet_button'),
          onPressed: _isLoading ? null : _connectWallet,
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            backgroundColor: const Color(0xFF9945FF), // Solana purple
            foregroundColor: Colors.white,
            disabledBackgroundColor: const Color(0xFF9945FF).withAlpha(128),
          ),
          child: _isLoading
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Connect wallet', style: TextStyle(fontSize: 16)),
        ),
      ],
    );
  }
}
