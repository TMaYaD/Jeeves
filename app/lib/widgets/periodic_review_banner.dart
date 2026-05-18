/// Dismissible banner shown above app-shell views when the Weekly Review is
/// due — or when the inbox and next-actions are both empty while deferred
/// lists (waiting-for or someday/maybe) still hold items.
///
/// Visibility rules — banner toggle must be enabled, the user must have at
/// least one todo (skip onboarding state), and dismissed-today must be false.
/// Given those, the banner shows when **either**:
/// - the review is "due" per the cadence (>= 7 days since last completion,
///   or never completed), **or**
/// - inbox + next-actions are both empty AND (waiting-for OR maybe) is
///   non-empty. This fills the gap left by [FocusSessionPlanningBanner]
///   (which suppresses itself in that state per #258) so the user is
///   nudged toward the weekly review when there is nothing to plan today
///   but deferred inventory remains.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/periodic_review_settings_provider.dart';

class PeriodicReviewBanner extends ConsumerWidget {
  const PeriodicReviewBanner({super.key});

  static const _quips = <_Quip>[
    _Quip('A weekly tidy, sir?', 'A trifling few minutes keeps the system humming.'),
    _Quip('If I might suggest, sir.', 'A weekly review keeps the chaos at bay.'),
    _Quip('Sir?', 'Your future self will, I venture, thank you.'),
    _Quip('Pardon me, sir.', 'Clear the decks. Set the week.'),
    _Quip('Shall we, sir?', 'Your list, audited and ready.'),
    _Quip('A moment, sir.', 'Ten minutes now, ten fewer worries later.'),
    _Quip('Ahem, sir.', 'Time to see what is actually going on.'),
  ];

  static _Quip _quipForToday() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final seed = today.difference(DateTime(2000)).inDays;
    return _quips[seed % _quips.length];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(periodicReviewBannerVisibleProvider)) {
      return const SizedBox.shrink();
    }

    return _BannerContent(
      key: const Key('periodic_review_banner_visible'),
      quip: _quipForToday(),
      onTap: () => context.go('/periodic-review'),
      onDismiss: () => ref
          .read(periodicReviewSettingsProvider.notifier)
          .dismissBannerForToday(),
    );
  }
}

class _Quip {
  const _Quip(this.title, this.sub);
  final String title;
  final String sub;
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
  // Teal/green palette to distinguish from amber (planning) and indigo
  // (shutdown). Pending #45's design system audit.
  static const _bg = Color(0xFFECFDF5);
  static const _accent = Color(0xFF059669);
  static const _ink = Color(0xFF065F46);
  static const _inkMuted = Color(0xFF047857);

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
          border: Border(bottom: BorderSide(color: Color(0x22059669))),
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
                  child: const Icon(Icons.refresh_rounded,
                      size: 22, color: _accent),
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
                _CtaPill(onTap: widget.onTap),
                const SizedBox(width: 4),
                GestureDetector(
                  key: const Key('periodic_review_banner_dismiss'),
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
  const _CtaPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF059669),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            'Start Weekly Review',
            style: TextStyle(
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
