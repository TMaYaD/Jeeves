/// Step 6 of the Weekly Review wizard: confirmation screen with stats and a
/// single Done button. Tapping Done persists the completion timestamp and
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

  Future<void> _onDone() async {
    if (_completing) return;
    setState(() => _completing = true);
    try {
      await ref.read(periodicReviewProvider.notifier).completeReview();
      if (!mounted) return;
      context.go('/inbox');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Couldn\'t complete the review: $e')),
      );
    } finally {
      if (mounted) setState(() => _completing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(periodicReviewProvider);
    final inboxProcessed = state.inboxNav.length;
    final captured = state.brainDumpAdded;
    final waitingReviewed = state.waitingForNav.length;
    final projectsReviewed = state.projectsNav.length;
    final somedayReviewed = state.somedayNav.length;
    final objectives = state.objectives
        .map((o) => o.trim())
        .where((o) => o.isNotEmpty)
        .toList();

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
              _StatRow(
                  label: 'Inbox processed',
                  value: inboxProcessed.toString()),
              _StatRow(
                  label: 'Items captured', value: captured.toString()),
              _StatRow(
                  label: 'Waiting-for reviewed',
                  value: waitingReviewed.toString()),
              _StatRow(
                  label: 'Projects reviewed',
                  value: projectsReviewed.toString()),
              _StatRow(
                  label: 'Someday reviewed',
                  value: somedayReviewed.toString()),
            ],
          ),
        ),
        if (objectives.isNotEmpty) ...[
          const SizedBox(height: 24),
          const Text(
            'Your objectives this week',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
              color: Color(0xFF6B7280),
            ),
          ),
          const SizedBox(height: 8),
          for (final o in objectives)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 7, right: 8),
                    child: Icon(Icons.fiber_manual_record,
                        size: 8, color: Color(0xFF059669)),
                  ),
                  Expanded(
                    child: Text(
                      o,
                      style: const TextStyle(
                          fontSize: 15, color: Color(0xFF1A1A2E)),
                    ),
                  ),
                ],
              ),
            ),
        ],
        const SizedBox(height: 32),
        FilledButton(
          key: const Key('periodic_review_done'),
          onPressed: _completing ? null : _onDone,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF059669),
            disabledBackgroundColor: const Color(0xFFD1D5DB),
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          child: const Text(
            'Done',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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
