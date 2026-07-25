import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/onboarding_provider.dart';
import 'jeeves_logo.dart';

/// A paired (header, subtitle) greeting for the onboarding card. Kept as a
/// pair so the header line and its subtitle are never shown mismatched.
class OnboardingGreeting {
  const OnboardingGreeting({required this.header, required this.subtitle});

  final String header;
  final String subtitle;
}

/// Jeeves-speak greetings for the empty-Inbox onboarding card — first person,
/// addressed to "sir", framing the Inbox as how you hand Jeeves what's on your
/// mind (see DESIGN.md § Voice). One pair is drawn at random per display, so
/// the app does not repeat itself; the paired shape stops a header ever pairing
/// with the wrong subtitle. Mirrors the nudge-banner pool pattern
/// (`lib/widgets/nudge_banner.dart`).
const onboardingGreetings = <OnboardingGreeting>[
  OnboardingGreeting(
    header: "You've a great deal on your mind, I expect, sir.",
    subtitle:
        "Unburden it all here — tasks, errands, half-formed plans. I'll hold them; you needn't.",
  ),
  OnboardingGreeting(
    header: "You've rather a lot rattling about, I fancy, sir.",
    subtitle:
        "Set it all down here — tasks, errands, half-formed schemes. I'll keep them; you needn't.",
  ),
  OnboardingGreeting(
    header: "A full head today, I gather, sir.",
    subtitle:
        "Let it all out here — tasks, errands, stray notions. I'll see them safe; you needn't.",
  ),
];

final _random = Random();

/// Picks one greeting at random. Pass [seed] in tests for a deterministic draw.
OnboardingGreeting pickOnboardingGreeting({int? seed}) {
  final rng = seed == null ? _random : Random(seed);
  return onboardingGreetings[rng.nextInt(onboardingGreetings.length)];
}

/// First-launch onboarding card shown in the inbox when the database is empty.
///
/// Self-hiding: collapses to [SizedBox.shrink] once the user has permanently
/// dismissed it (via [onboardingSeenNotifier]) or once any todo exists in the
/// database (via [hasAnyItemProvider]).
class OnboardingCard extends ConsumerWidget {
  const OnboardingCard({super.key, this.greetingSeed});

  /// Optional deterministic seed for the greeting draw, used by tests. Null in
  /// production so each display draws afresh.
  final int? greetingSeed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Auto-dismiss silently the moment any todo appears (e.g. after a Nirvana
    // import) so the card never re-surfaces without user action.
    ref.listen<AsyncValue<bool>>(hasAnyItemProvider, (_, next) {
      if (next.asData?.value == true) markOnboardingSeen();
    });

    return ValueListenableBuilder<bool>(
      valueListenable: onboardingSeenNotifier,
      builder: (context, seen, _) {
        if (seen) return const SizedBox.shrink();

        final hasAnyItemAsync = ref.watch(hasAnyItemProvider);
        final hasAnyItem = hasAnyItemAsync.asData?.value;
        if (hasAnyItem == null || hasAnyItem) return const SizedBox.shrink();

        return _OnboardingCardContent(
          key: const Key('onboarding_card'),
          greetingSeed: greetingSeed,
          onStartFresh: () => markOnboardingSeen(),
          onImportFromNirvana: () {
            markOnboardingSeen();
            context.push('/import');
          },
          onSignIn: () {
            markOnboardingSeen();
            context.push('/login');
          },
        );
      },
    );
  }
}

class _OnboardingCardContent extends StatefulWidget {
  const _OnboardingCardContent({
    super.key,
    required this.onStartFresh,
    required this.onImportFromNirvana,
    required this.onSignIn,
    this.greetingSeed,
  });

  final VoidCallback onStartFresh;
  final VoidCallback onImportFromNirvana;
  final VoidCallback onSignIn;
  final int? greetingSeed;

  @override
  State<_OnboardingCardContent> createState() => _OnboardingCardContentState();
}

class _OnboardingCardContentState extends State<_OnboardingCardContent> {
  static const _ink = Color(0xFF1A1A2E);
  static const _inkMuted = Color(0xFF6B7280);

  // Drawn once per display so the greeting stays stable across rebuilds.
  late final OnboardingGreeting _greeting =
      pickOnboardingGreeting(seed: widget.greetingSeed);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: logo + Jeeves greeting (header line + subtitle).
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const JeevesLogo(size: 32, variant: JeevesLogoVariant.signature),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _greeting.header,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: _ink,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _greeting.subtitle,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: _inkMuted,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Divider(height: 1, color: Color(0xFFBFDBFE)),
          ),
          // Action rows
          _ActionRow(
            key: const Key('onboarding_start_fresh'),
            icon: Icons.inbox_outlined,
            label: 'Start fresh',
            isPrimary: true,
            onTap: widget.onStartFresh,
          ),
          _ActionRow(
            key: const Key('onboarding_import'),
            icon: Icons.upload_file_outlined,
            label: 'Import from Nirvana export',
            onTap: widget.onImportFromNirvana,
          ),
          _ActionRow(
            key: const Key('onboarding_sign_in'),
            icon: Icons.cloud_outlined,
            label: 'Sign in to sync',
            onTap: widget.onSignIn,
          ),
          const SizedBox(height: 4),
        ],
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
