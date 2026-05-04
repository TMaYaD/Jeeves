import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/onboarding_provider.dart';
import 'jeeves_logo.dart';

/// First-launch onboarding card shown in the inbox when the database is empty.
///
/// Self-hiding: collapses to [SizedBox.shrink] once the user has permanently
/// dismissed it (via [onboardingSeenNotifier]) or once any todo exists in the
/// database (via [hasTodosProvider]).
class OnboardingCard extends ConsumerWidget {
  const OnboardingCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Auto-dismiss silently the moment any todo appears (e.g. after a Nirvana
    // import) so the card never re-surfaces without user action.
    ref.listen<AsyncValue<bool>>(hasTodosProvider, (_, next) {
      if (next.asData?.value == true) markOnboardingSeen();
    });

    return ValueListenableBuilder<bool>(
      valueListenable: onboardingSeenNotifier,
      builder: (context, seen, _) {
        if (seen) return const SizedBox.shrink();

        final hasTodos = ref.watch(hasTodosProvider).asData?.value ?? false;
        if (hasTodos) return const SizedBox.shrink();

        return _OnboardingCardContent(
          key: const Key('onboarding_card'),
          onStartFresh: () => markOnboardingSeen(),
          onImportFromNirvana: () {
            markOnboardingSeen();
            context.push('/import');
          },
          onSignIn: () {
            markOnboardingSeen();
            context.push('/login');
          },
          onDismiss: () => markOnboardingSeen(),
        );
      },
    );
  }
}

class _OnboardingCardContent extends StatelessWidget {
  const _OnboardingCardContent({
    super.key,
    required this.onStartFresh,
    required this.onImportFromNirvana,
    required this.onSignIn,
    required this.onDismiss,
  });

  final VoidCallback onStartFresh;
  final VoidCallback onImportFromNirvana;
  final VoidCallback onSignIn;
  final VoidCallback onDismiss;

  static const _bg = Color(0xFFEFF6FF); // blue-50
  static const _ink = Color(0xFF1A1A2E);
  static const _inkMuted = Color(0xFF6B7280); // gray-500

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Container(
        decoration: BoxDecoration(
          color: _bg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFBFDBFE)), // blue-200
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: logo + dismiss button
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const JeevesLogo(size: 32, variant: JeevesLogoVariant.signature),
                  const SizedBox(width: 4),
                  const Expanded(
                    child: Text(
                      'Your GTD inbox, sir. Shall we stock it?',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: _ink,
                        height: 1.3,
                      ),
                    ),
                  ),
                  Semantics(
                    button: true,
                    label: 'Dismiss onboarding',
                    child: GestureDetector(
                      key: const Key('onboarding_dismiss'),
                      behavior: HitTestBehavior.opaque,
                      onTap: onDismiss,
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(Icons.close, size: 18, color: _inkMuted),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Divider(height: 1, color: Color(0xFFBFDBFE)),
            ),
            // Action rows
            _ActionRow(
              key: const Key('onboarding_start_fresh'),
              icon: Icons.inbox_outlined,
              label: 'Start fresh',
              isPrimary: true,
              onTap: onStartFresh,
            ),
            _ActionRow(
              key: const Key('onboarding_import'),
              icon: Icons.upload_file_outlined,
              label: 'Import from Nirvana export',
              onTap: onImportFromNirvana,
            ),
            _ActionRow(
              key: const Key('onboarding_sign_in'),
              icon: Icons.cloud_outlined,
              label: 'Sign in to sync',
              onTap: onSignIn,
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.isPrimary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isPrimary;

  static const _accent = Color(0xFF2667B7);
  static const _ink = Color(0xFF1A1A2E);
  static const _inkMuted = Color(0xFF6B7280);

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: isPrimary ? _accent : _inkMuted,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: isPrimary ? FontWeight.w600 : FontWeight.w500,
                  color: isPrimary ? _accent : _ink,
                ),
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: 18,
              color: isPrimary ? _accent : _inkMuted,
            ),
          ],
        ),
      ),
    );
  }
}
