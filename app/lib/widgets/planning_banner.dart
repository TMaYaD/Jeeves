import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/daily_planning_provider.dart';
import '../providers/planning_settings_provider.dart';

/// A dismissible banner shown at the top of shell views when the daily
/// planning ritual is incomplete and the user hasn't dismissed it today.
///
/// Tapping opens the ritual at step 1. The × button hides the banner for
/// the rest of the day. Both state changes survive app restarts.
class PlanningBanner extends ConsumerWidget {
  const PlanningBanner({super.key});

  /// Jeevesian quips — picked deterministically per day so the copy is stable
  /// within a session but refreshes each morning.
  static const _quips = <_Quip>[
    _Quip(
      'Shall we, sir?',
      'One prefers the day with a touch of forethought.',
      'Very good  \u2192',
    ),
    _Quip(
      'A moment to plan, sir?',
      'The day has a way of escaping unsupervised.',
      'At once  \u2192',
    ),
    _Quip(
      'If I may, sir\u2026',
      'The day is not, regrettably, going to plan itself.',
      'Indeed  \u2192',
    ),
    _Quip(
      'Might I suggest, sir?',
      'One finds the day more obliging when given instructions.',
      'Quite  \u2192',
    ),
    _Quip(
      'Pardon me, sir.',
      'I have taken the liberty of reserving a moment for planning.',
      'Very good  \u2192',
    ),
    _Quip(
      'Sir?',
      'A trifling five minutes before the day absconds with you.',
      'At once  \u2192',
    ),
    _Quip(
      'Ahem, sir.',
      'The day awaits your instructions.',
      'Indeed  \u2192',
    ),
  ];

  static _Quip _quipForToday() {
    final now = DateTime.now();
    // Stable within a calendar day, changes across days.
    final seed = now.year * 366 + now.month * 31 + now.day;
    return _quips[seed % _quips.length];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(planningSettingsProvider);
    if (!settings.bannerEnabled) return const SizedBox.shrink();

    return ValueListenableBuilder<bool>(
      valueListenable: planningCompletionNotifier,
      builder: (context, completed, _) {
        if (completed) return const SizedBox.shrink();
        return ValueListenableBuilder<bool>(
          valueListenable: bannerDismissedNotifier,
          builder: (context, dismissed, _) {
            if (dismissed) return const SizedBox.shrink();
            return _BannerContent(
              key: const Key('planning_banner_visible'),
              quip: _quipForToday(),
              onTap: () => context.go('/planning'),
              onDismiss: () =>
                  ref.read(dailyPlanningProvider.notifier).dismissBannerForToday(),
            );
          },
        );
      },
    );
  }
}

class _Quip {
  const _Quip(this.title, this.sub, this.cta);
  final String title;
  final String sub;
  final String cta;
}

class _BannerContent extends StatefulWidget {
  const _BannerContent({
    super.key,
    required this.quip,
    required this.onTap,
    required this.onDismiss,
  });

  final _Quip quip;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  @override
  State<_BannerContent> createState() => _BannerContentState();
}

class _BannerContentState extends State<_BannerContent>
    with SingleTickerProviderStateMixin {
  // Amber palette — warm and urgent without tipping into alarm-red.
  static const _bg = Color(0xFFFEF3C7); // amber-100
  static const _accent = Color(0xFFD97706); // amber-600
  static const _ink = Color(0xFF78350F); // amber-900
  static const _inkMuted = Color(0xFF92400E); // amber-800

  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        decoration: const BoxDecoration(
          color: _bg,
          border: Border(
            bottom: BorderSide(color: Color(0x22D97706)),
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Row(
              children: [
                ScaleTransition(
                  scale: Tween<double>(begin: 0.92, end: 1.08).animate(
                    CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
                  ),
                  child: const Icon(Icons.wb_sunny, size: 22, color: _accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.quip.title,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: _ink,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.quip.sub,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: _inkMuted,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _CtaPill(label: widget.quip.cta, onTap: widget.onTap),
                const SizedBox(width: 4),
                GestureDetector(
                  key: const Key('planning_banner_dismiss'),
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onDismiss,
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(Icons.close, size: 18, color: _inkMuted),
                  ),
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
  const _CtaPill({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFD97706),
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
