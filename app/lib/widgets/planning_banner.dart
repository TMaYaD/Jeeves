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

class _BannerContent extends StatelessWidget {
  const _BannerContent({required this.onTap, required this.onDismiss});

  final VoidCallback onTap;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        color: const Color(0xFFEFF6FF),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.wb_sunny_outlined,
                    size: 18, color: Color(0xFF2563EB)),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Plan your day \u2192',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1D4ED8),
                    ),
                  ),
                ),
                GestureDetector(
                  key: const Key('planning_banner_dismiss'),
                  behavior: HitTestBehavior.opaque,
                  onTap: onDismiss,
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.close, size: 18, color: Color(0xFF6B7280)),
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
