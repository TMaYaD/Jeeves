/// Single in-app Banner surface for every Ritual's Nudge. Consumes the
/// **Nudge queue** (see `CONTEXT.md`'s **Banner** and **Nudge queue**
/// entries) — renders the highest-priority Ritual whose Nudge is currently
/// visible and whose banner-enabled setting is `true`. Tapping opens the
/// Ceremony; the ✕ maps to a Nudge **dismiss** (current firing).
///
/// Replaces the three bespoke per-Ritual banner widgets with one
/// queue-driven widget parametrised by a per-Ritual chrome matrix.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/ritual.dart';
import '../providers/focus_session_planning_settings_provider.dart';
import '../providers/nudge_provider.dart';
import '../providers/periodic_review_settings_provider.dart'
    show periodicReviewBannerEnabledProvider;
import '../providers/shutdown_settings_provider.dart';

/// True iff the in-app Banner for [ritual] is enabled in user settings.
/// Each Ritual has its own enabled flag because the user might want to
/// silence one Ritual's in-app nag without silencing the rest.
final nudgeBannerEnabledProvider = Provider.family<bool, RitualId>((ref, ritual) {
  return switch (ritual) {
    RitualId.dailyPlanning =>
      ref.watch(focusSessionPlanningSettingsProvider).bannerEnabled,
    RitualId.eveningShutdown => ref.watch(shutdownSettingsProvider).bannerEnabled,
    RitualId.weeklyReview => ref.watch(periodicReviewBannerEnabledProvider),
  };
});

/// The Ritual whose Banner should currently render — the head of the
/// Nudge queue whose per-surface banner is enabled. Walks down the queue
/// rather than returning null when the head's banner is disabled, so a
/// silenced higher-priority Ritual does not hide a still-visible lower one.
final bannerVisibleRitualProvider = Provider<RitualId?>((ref) {
  final queue = ref.watch(nudgeQueueProvider);
  for (final r in queue) {
    if (ref.watch(nudgeBannerEnabledProvider(r))) return r;
  }
  return null;
});

class NudgeBanner extends ConsumerWidget {
  const NudgeBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ritual = ref.watch(bannerVisibleRitualProvider);
    if (ritual == null) return const SizedBox.shrink();

    final skin = _skins[ritual]!;
    final quip = skin.quipForToday();

    return _BannerContent(
      key: Key('${ritual.keyPrefix}_banner_visible'),
      ritual: ritual,
      skin: skin,
      quip: quip,
      onTap: () => context.go(skin.route),
      onDismiss: () =>
          ref.read(nudgeActionsProvider).dismiss(ritual),
    );
  }
}

// ---------------------------------------------------------------------------
// Per-Ritual skin matrix
// ---------------------------------------------------------------------------

class _Quip {
  const _Quip(this.title, this.sub, this.cta);
  final String title;
  final String sub;
  final String cta;
}

class _Skin {
  const _Skin({
    required this.quips,
    required this.quipSeedOffset,
    required this.route,
    required this.bg,
    required this.accent,
    required this.ink,
    required this.inkMuted,
    required this.borderTint,
    required this.icon,
    required this.pulseDuration,
    required this.pulseFromScale,
    required this.pulseToScale,
    this.hardCtaLabel,
  });

  final List<_Quip> quips;
  final int quipSeedOffset;
  final String route;
  final Color bg;
  final Color accent;
  final Color ink;
  final Color inkMuted;
  final int borderTint;
  final IconData icon;
  final Duration pulseDuration;
  final double pulseFromScale;
  final double pulseToScale;

  /// When non-null, overrides the quip's CTA label (used by Weekly Review
  /// which keeps a stable "Start Weekly Review" pill regardless of the
  /// quip text).
  final String? hardCtaLabel;

  _Quip quipForToday() {
    final now = DateTime.now();
    final seed = now.year * 366 + now.month * 31 + now.day + quipSeedOffset;
    return quips[seed % quips.length];
  }
}

final _skins = <RitualId, _Skin>{
  RitualId.dailyPlanning: const _Skin(
    quips: [
      _Quip('Shall we, sir?',
          'One prefers the day with a touch of forethought.',
          'Very good  →'),
      _Quip('A moment to plan, sir?',
          'The day has a way of escaping unsupervised.',
          'At once  →'),
      _Quip('If I may, sir…',
          'The day is not, regrettably, going to plan itself.',
          'Indeed  →'),
      _Quip('Might I suggest, sir?',
          'One finds the day more obliging when given instructions.',
          'Quite  →'),
      _Quip('Pardon me, sir.',
          'I have taken the liberty of reserving a moment for planning.',
          'Very good  →'),
      _Quip('Sir?',
          'A trifling five minutes before the day absconds with you.',
          'At once  →'),
      _Quip('Ahem, sir.', 'The day awaits your instructions.',
          'Indeed  →'),
    ],
    quipSeedOffset: 0,
    route: '/focus-session-planning',
    bg: Color(0xFFFEF3C7), // amber-100
    accent: Color(0xFFD97706), // amber-600
    ink: Color(0xFF78350F), // amber-900
    inkMuted: Color(0xFF92400E), // amber-800
    borderTint: 0x22D97706,
    icon: Icons.wb_sunny,
    pulseDuration: Duration(milliseconds: 1400),
    pulseFromScale: 0.92,
    pulseToScale: 1.08,
  ),
  RitualId.eveningShutdown: const _Skin(
    quips: [
      _Quip('A moment, sir?',
          'The day’s accounts require your attention before we close.',
          'Very good  →'),
      _Quip('If I may, sir…',
          'One prefers the evening with a touch of reflection.',
          'At once  →'),
      _Quip('Shall we close out, sir?',
          'Tomorrow is better served by a tidy ledger today.',
          'Indeed  →'),
      _Quip('Sir, the hour is nigh.',
          'A brief review before the curtain falls, perhaps?',
          'Quite  →'),
      _Quip('Pardon the intrusion, sir.',
          'One has taken the liberty of preparing the day’s summary.',
          'Very good  →'),
    ],
    quipSeedOffset: 3,
    route: '/shutdown',
    bg: Color(0xFFEEF2FF), // indigo-50
    accent: Color(0xFF4F46E5), // indigo-600
    ink: Color(0xFF1E1B4B), // indigo-950
    inkMuted: Color(0xFF3730A3), // indigo-800
    borderTint: 0x224F46E5,
    icon: Icons.nightlight_round,
    pulseDuration: Duration(milliseconds: 2000),
    pulseFromScale: 0.90,
    pulseToScale: 1.08,
  ),
  RitualId.weeklyReview: const _Skin(
    quips: [
      _Quip('A weekly tidy, sir?',
          'A trifling few minutes keeps the system humming.', ''),
      _Quip('If I might suggest, sir.',
          'A weekly review keeps the chaos at bay.', ''),
      _Quip('Sir?', 'Your future self will, I venture, thank you.', ''),
      _Quip('Pardon me, sir.', 'Clear the decks. Set the week.', ''),
      _Quip('Shall we, sir?', 'Your list, audited and ready.', ''),
      _Quip('A moment, sir.', 'Ten minutes now, ten fewer worries later.', ''),
      _Quip('Ahem, sir.', 'Time to see what is actually going on.', ''),
    ],
    quipSeedOffset: 0,
    route: '/periodic-review',
    bg: Color(0xFFECFDF5), // emerald-50
    accent: Color(0xFF059669), // emerald-600
    ink: Color(0xFF065F46), // emerald-900
    inkMuted: Color(0xFF047857), // emerald-800
    borderTint: 0x22059669,
    icon: Icons.refresh_rounded,
    pulseDuration: Duration(milliseconds: 1400),
    pulseFromScale: 0.92,
    pulseToScale: 1.08,
    hardCtaLabel: 'Start Weekly Review',
  ),
};

// ---------------------------------------------------------------------------
// Banner chrome — shared between all Rituals, parametrised by [_Skin].
// ---------------------------------------------------------------------------

class _BannerContent extends StatefulWidget {
  const _BannerContent({
    super.key,
    required this.ritual,
    required this.skin,
    required this.quip,
    required this.onTap,
    required this.onDismiss,
  });

  final RitualId ritual;
  final _Skin skin;
  final _Quip quip;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  @override
  State<_BannerContent> createState() => _BannerContentState();
}

class _BannerContentState extends State<_BannerContent>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: widget.skin.pulseDuration)
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final skin = widget.skin;
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        decoration: BoxDecoration(
          color: skin.bg,
          border: Border(bottom: BorderSide(color: Color(skin.borderTint))),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Row(
              children: [
                ScaleTransition(
                  scale: Tween<double>(
                    begin: skin.pulseFromScale,
                    end: skin.pulseToScale,
                  ).animate(
                    CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
                  ),
                  child: Icon(skin.icon, size: 22, color: skin.accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.quip.title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: skin.ink,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.quip.sub,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: skin.inkMuted,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _CtaPill(
                  label: skin.hardCtaLabel ?? widget.quip.cta,
                  color: skin.accent,
                  onTap: widget.onTap,
                ),
                const SizedBox(width: 4),
                IconButton(
                  key: Key('${widget.ritual.keyPrefix}_banner_dismiss'),
                  tooltip: 'Dismiss',
                  onPressed: widget.onDismiss,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(),
                  icon: Icon(Icons.close, size: 18, color: skin.inkMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CtaPill extends StatelessWidget {
  const _CtaPill({
    required this.label,
    required this.color,
    required this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ),
    );
  }
}
