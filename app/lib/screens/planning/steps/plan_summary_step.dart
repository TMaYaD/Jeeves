/// Step 5 of the daily planning ritual: summary and commit.
///
/// Shows:
/// - The full list of tasks selected for today, sorted by priority:
///   due date (ascending) → scheduled → next actions.
/// - A colour-coded capacity bar (green ≤ 80 %, amber ≤ 100 %, red > 100 %).
/// - An over-capacity warning with a "Review Selections" back-link to Step 2.
/// - A "Start Day" button that finalises the plan and unlocks execution.
///
/// Available time is entered in Step 1 (Day Check-in).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../providers/daily_planning_provider.dart';

class PlanSummaryStep extends ConsumerWidget {
  const PlanSummaryStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final planningState = ref.watch(dailyPlanningProvider);
    final availableMinutes = planningState.availableMinutes;
    final asyncSelected = ref.watch(todaySelectedTasksProvider);

    return asyncSelected.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Error: $err')),
      data: (rawTasks) {
        // Sort: tasks with a due date first (ascending), then scheduled
        // without a due date, then everything else (next actions).
        final tasks = _sortTasks(rawTasks);

        final totalMinutes =
            tasks.fold<int>(0, (sum, t) => sum + (t.timeEstimate ?? 0));
        final ratio = availableMinutes > 0
            ? totalMinutes / availableMinutes
            : double.infinity;
        final overCapacity = ratio > 1.0;

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            // --- Capacity bar ---
            _SectionLabel('Capacity'),
            const SizedBox(height: 8),
            _CapacityBar(ratio: ratio.clamp(0.0, 2.0)),
            const SizedBox(height: 6),
            Text(
              _capacitySummary(tasks.length, totalMinutes, availableMinutes),
              style: TextStyle(fontSize: 13, color: Colors.grey[600]),
            ),
            if (overCapacity) ...[
              const SizedBox(height: 10),
              _OverCapacityWarning(
                // Step 2 = Next Actions review (was step 0 in old 4-step flow)
                onReview: () =>
                    ref.read(dailyPlanningProvider.notifier).goToStep(2),
              ),
            ],
            const SizedBox(height: 20),

            // --- Task list ---
            _SectionLabel('Today\'s tasks (${tasks.length})'),
            const SizedBox(height: 8),
            if (tasks.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'No tasks selected — go back and select some!',
                  style: TextStyle(fontSize: 14, color: Colors.grey[400]),
                  textAlign: TextAlign.center,
                ),
              )
            else
              ...tasks.map((t) => _SelectedTaskRow(todo: t)),

            const SizedBox(height: 28),

            // --- Start Day button ---
            FilledButton(
              onPressed: () => _startDay(context, ref),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text(
                'Start Day',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Sorts selected tasks: due-date tasks (closest first) → scheduled → rest.
  List<Todo> _sortTasks(List<Todo> tasks) {
    final withDue = tasks.where((t) => t.dueDate != null).toList()
      ..sort((a, b) => a.dueDate!.compareTo(b.dueDate!));
    final scheduledNoDue = tasks
        .where((t) => t.dueDate == null && t.state == GtdState.scheduled.value)
        .toList();
    final rest = tasks
        .where((t) => t.dueDate == null && t.state != GtdState.scheduled.value)
        .toList();
    return [...withDue, ...scheduledNoDue, ...rest];
  }

  Future<void> _startDay(BuildContext context, WidgetRef ref) async {
    // Capture any error so all context usage stays after a single mounted check.
    Object? startError;
    try {
      await ref.read(dailyPlanningProvider.notifier).startDay();
    } catch (e) {
      startError = e;
    }
    if (!context.mounted) return;
    if (startError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to start day: $startError')),
      );
      return;
    }
    context.go('/next-actions');
  }

  String _capacitySummary(int count, int totalMinutes, int availableMinutes) {
    final planned = _formatMinutes(totalMinutes);
    final available = _formatMinutes(availableMinutes);
    return '$count task${count == 1 ? '' : 's'} · $planned planned of $available available';
  }

  String _formatMinutes(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return '${m}m';
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }
}

// ---------------------------------------------------------------------------
// Widgets
// ---------------------------------------------------------------------------

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.2,
        color: Color(0xFF9CA3AF),
      ),
    );
  }
}

class _CapacityBar extends StatelessWidget {
  const _CapacityBar({required this.ratio});

  final double ratio;

  @override
  Widget build(BuildContext context) {
    final Color barColor;
    if (ratio <= 0.8) {
      barColor = const Color(0xFF16A34A);
    } else if (ratio <= 1.0) {
      barColor = const Color(0xFFF59E0B);
    } else {
      barColor = const Color(0xFFDC2626);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(
        value: ratio.clamp(0.0, 1.0),
        minHeight: 10,
        backgroundColor: const Color(0xFFE5E7EB),
        valueColor: AlwaysStoppedAnimation<Color>(barColor),
      ),
    );
  }
}

class _OverCapacityWarning extends StatelessWidget {
  const _OverCapacityWarning({required this.onReview});
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFCA5A5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded,
              color: Color(0xFFDC2626), size: 18),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'You\'re over capacity. Consider deferring some tasks.',
              style: TextStyle(fontSize: 13, color: Color(0xFFB91C1C)),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onReview,
            style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFDC2626),
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            child: const Text('Review',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}

class _SelectedTaskRow extends StatelessWidget {
  const _SelectedTaskRow({required this.todo});
  final Todo todo;

  @override
  Widget build(BuildContext context) {
    final estimate = todo.timeEstimate;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.check_circle_outline,
              size: 18, color: Color(0xFF16A34A)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  todo.title,
                  style: const TextStyle(
                      fontSize: 14, color: Color(0xFF1A1A2E)),
                ),
                if (todo.dueDate != null)
                  Text(
                    'Due ${todo.dueDate!.year}-'
                    '${todo.dueDate!.month.toString().padLeft(2, '0')}-'
                    '${todo.dueDate!.day.toString().padLeft(2, '0')}',
                    style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                  ),
              ],
            ),
          ),
          if (estimate != null)
            Text(
              estimate < 60
                  ? '${estimate}m'
                  : estimate % 60 == 0
                      ? '${estimate ~/ 60}h'
                      : '${estimate ~/ 60}h ${estimate % 60}m',
              style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey[500],
                  fontWeight: FontWeight.w500),
            ),
        ],
      ),
    );
  }
}
