import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/evening_shutdown_provider.dart';
import '../providers/focus_session_planning_provider.dart'
    show focusSessionPlanningCompletionNotifier;
import '../providers/shutdown_settings_provider.dart';

/// A dismissible banner shown at the top of shell views when the evening
/// shutdown ritual is due (planning complete, shutdown not yet done, and
/// banner not dismissed today).
///
/// Only shown after the user-configured shutdown time so it doesn't distract
/// during the working day.
class ShutdownBanner extends ConsumerStatefulWidget {
  const ShutdownBanner({super.key});

  static const _quips = <_Quip>[
    _Quip(
      'A moment, sir?',
      'The day\'s accounts require your attention before we close.',
      'Very good  \u2192',
    ),
    _Quip(
      'If I may, sir\u2026',
      'One prefers the evening with a touch of reflection.',
      'At once  \u2192',
    ),
    _Quip(
      'Shall we close out, sir?',
      'Tomorrow is better served by a tidy ledger today.',
      'Indeed  \u2192',
    ),
    _Quip(
      'Sir, the hour is nigh.',
      'A brief review before the curtain falls, perhaps?',
      'Quite  \u2192',
    ),
    _Quip(
      'Pardon the intrusion, sir.',
      'One has taken the liberty of preparing the day\'s summary.',
      'Very good  \u2192',
    ),
  ];

  static _Quip _quipForToday() {
    final now = DateTime.now();
    final seed = now.year * 366 + now.month * 31 + now.day + 3;
    return _quips[seed % _quips.length];
  }

  @override
  ConsumerState<ShutdownBanner> createState() => _ShutdownBannerState();
}

class _ShutdownBannerState extends ConsumerState<ShutdownBanner> {
  Timer? _wakeTimer;

  @override
  void dispose() {
    _wakeTimer?.cancel();
    super.dispose();
  }

  void _scheduleWakeAt(TimeOfDay shutdownTime) {
    _wakeTimer?.cancel();
    final now = TimeOfDay.now();
    final nowMinutes = now.hour * 60 + now.minute;
    final targetMinutes = shutdownTime.hour * 60 + shutdownTime.minute;
    if (targetMinutes <= nowMinutes) return;
    _wakeTimer = Timer(
      Duration(minutes: targetMinutes - nowMinutes),
      () { if (mounted) setState(() {}); },
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(shutdownSettingsProvider);
    if (!settings.bannerEnabled) return const SizedBox.shrink();

    final now = TimeOfDay.now();
    final shutdownTime = settings.shutdownTime;
    final isAfterShutdownTime = now.hour > shutdownTime.hour ||
        (now.hour == shutdownTime.hour && now.minute >= shutdownTime.minute);
    if (!isAfterShutdownTime) {
      _scheduleWakeAt(shutdownTime);
      return const SizedBox.shrink();
    }

    return AnimatedBuilder(
      animation: Listenable.merge([
        focusSessionPlanningCompletionNotifier,
        shutdownCompletionNotifier,
        shutdownBannerDismissedNotifier,
      ]),
      builder: (context, _) {
        if (!focusSessionPlanningCompletionNotifier.value) {
          return const SizedBox.shrink();
        }
        if (shutdownCompletionNotifier.value) return const SizedBox.shrink();
        if (shutdownBannerDismissedNotifier.value) return const SizedBox.shrink();
        return _BannerContent(
          key: const Key('shutdown_banner_visible'),
          quip: ShutdownBanner._quipForToday(),
          onTap: () => context.go('/shutdown'),
          onDismiss: () => ref
              .read(eveningShutdownProvider.notifier)
              .dismissBannerForToday(),
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
  // Indigo/navy palette — calm, end-of-day feel.
  static const _bg = Color(0xFFEEF2FF); // indigo-50
  static const _accent = Color(0xFF4F46E5); // indigo-600
  static const _ink = Color(0xFF1E1B4B); // indigo-950
  static const _inkMuted = Color(0xFF3730A3); // indigo-800

  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
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
            bottom: BorderSide(color: Color(0x224F46E5)),
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Row(
              children: [
                ScaleTransition(
                  scale: Tween<double>(begin: 0.90, end: 1.08).animate(
                    CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
                  ),
                  child:
                      const Icon(Icons.nightlight_round, size: 22, color: _accent),
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
                  key: const Key('shutdown_banner_dismiss'),
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
      color: const Color(0xFF4F46E5),
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
