import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/clock_provider.dart';
import '../../providers/nudge_clock_provider.dart' show nudgeBoundaryTickProvider;
import '../../providers/system_trust_provider.dart';

const Color _kTickGreen = Color(0xFF16A34A);
const Color _kInk = Color(0xFF1A1A2E);
const Color _kSubtitleGrey = Color(0xFF6B7280);

/// The SYSTEM TRUST section of Settings (issue #52). Shape carries the state,
/// not colour: a filled green tick when good, an empty ink ring when the signal
/// needs attention. No number, no amber. Each row opens the place to fix it.
class SystemTrustSection extends ConsumerWidget {
  const SystemTrustSection({super.key});

  static const headerGlyphKey = Key('system_trust_header_glyph');
  static const inboxRowKey = Key('system_trust_inbox_row');
  static const weeklyReviewRowKey = Key('system_trust_weekly_review_row');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trust = ref.watch(systemTrustProvider);
    // Re-render at every local midnight so "N days ago" stays true.
    ref.watch(nudgeBoundaryTickProvider);
    final now = ref.watch(clockProvider)();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'SYSTEM TRUST',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                    color: Color(0xFF9CA3AF),
                  ),
                ),
              ),
              _Glyph(key: headerGlyphKey, needsAttention: trust.needsAttention),
            ],
          ),
        ),
        for (final signal in trust.signals)
          switch (signal.kind) {
            TrustSignalKind.inbox => ListTile(
                key: inboxRowKey,
                title: const Text('Captures in the Inbox'),
                trailing: _Glyph(needsAttention: signal.needsAttention),
                onTap: () => context.go('/inbox'),
              ),
            TrustSignalKind.weeklyReview => ListTile(
                key: weeklyReviewRowKey,
                title: const Text('Last Weekly Review'),
                subtitle: Text(
                  _lastReviewText(signal.lastReviewedAt, now),
                  style:
                      const TextStyle(fontSize: 12, color: _kSubtitleGrey),
                ),
                trailing: _Glyph(needsAttention: signal.needsAttention),
                onTap: () => context.push('/periodic-review'),
              ),
          },
      ],
    );
  }

  static String _lastReviewText(DateTime? lastReviewedAt, DateTime now) {
    if (lastReviewedAt == null) return 'not done yet';
    final last = lastReviewedAt.toLocal();
    final today = now.toLocal();
    final days = DateTime.utc(today.year, today.month, today.day)
        .difference(DateTime.utc(last.year, last.month, last.day))
        .inDays;
    return days == 1 ? '1 day ago' : '$days days ago';
  }
}

class _Glyph extends StatelessWidget {
  const _Glyph({super.key, required this.needsAttention});

  final bool needsAttention;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: needsAttention ? 'Needs attention' : 'All good',
      excludeSemantics: true,
      child: Icon(
        needsAttention ? Icons.circle_outlined : Icons.check_circle,
        color: needsAttention ? _kInk : _kTickGreen,
        size: 20,
      ),
    );
  }
}
