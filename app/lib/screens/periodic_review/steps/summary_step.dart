/// Final step of the Weekly Review wizard: confirmation screen with stats and
/// a single Done button. Tapping Done persists the completion timestamp and
/// returns the user to /inbox.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../providers/periodic_review_provider.dart';

class SummaryStep extends ConsumerStatefulWidget {
  const SummaryStep({super.key});

  @override
  ConsumerState<SummaryStep> createState() => _SummaryStepState();
}

class _SummaryStepState extends ConsumerState<SummaryStep> {
  bool _completing = false;
  String? _completeError;

  Future<void> _onDone() async {
    if (_completing) return;
    setState(() {
      _completing = true;
      _completeError = null;
    });
    try {
      await ref.read(periodicReviewProvider.notifier).completeReview();
      if (!mounted) return;
      context.go('/inbox');
    } catch (e) {
      if (!mounted) return;
      setState(() => _completeError = e.toString());
    } finally {
      if (mounted) setState(() => _completing = false);
    }
  }

  /// Renders `routed / total` so the user sees what they actually
  /// changed against the snapshot they walked through. Falls back to a
  /// plain count when nothing was loaded so the row still says "0".
  String _stat(int routed, int total) =>
      total == 0 ? '0' : '$routed / $total';

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(periodicReviewProvider);
    // Stats reflect what the user *did*, not what was *available*. Routings
    // map keys are the cursor indices on which the user ran a real
    // RoutingKind transition (Mark Done, Move to Maybe, etc); per-step
    // "Keep" actions intentionally don't enter the map because they are
    // stamping no-ops, not changes. The denominator is the snapshot size
    // so the user can see "I changed 3 of 12".
    final inboxProcessed =
        _stat(state.inboxRoutings.length, state.inboxNav.length);
    final waitingReviewed =
        _stat(state.waitingForRoutings.length, state.waitingForNav.length);
    final nextActionsReviewed = _stat(
        state.nextActionsRoutings.length, state.nextActionsNav.length);
    final somedayReviewed =
        _stat(state.somedayRoutings.length, state.somedayNav.length);

    return ListView(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      children: [
        const Center(
          child: Icon(Icons.check_circle, size: 88, color: Color(0xFF059669)),
        ),
        const SizedBox(height: 24),
        const Center(
          child: Text(
            'Weekly Review Complete',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A1A2E),
            ),
          ),
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFF9FAFB),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Column(
            children: [
              _StatRow(label: 'Inbox processed', value: inboxProcessed),
              _StatRow(label: 'Waiting-for routed', value: waitingReviewed),
              _StatRow(label: 'Next actions routed', value: nextActionsReviewed),
              _StatRow(label: 'Someday routed', value: somedayReviewed),
            ],
          ),
        ),
        const SizedBox(height: 32),
        if (_completeError != null) ...[
          Container(
            key: const Key('periodic_review_complete_error'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF2F2),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFFCA5A5)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline,
                    size: 18, color: Color(0xFFB91C1C)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "Couldn't complete the review: $_completeError",
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF991B1B),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        FilledButton(
          key: const Key('periodic_review_done'),
          onPressed: _completing ? null : _onDone,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF059669),
            disabledBackgroundColor: const Color(0xFFD1D5DB),
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          child: Text(
            _completeError != null ? 'Retry' : 'Done',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                  fontSize: 14, color: Color(0xFF6B7280)),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Color(0xFF1A1A2E),
            ),
          ),
        ],
      ),
    );
  }
}
