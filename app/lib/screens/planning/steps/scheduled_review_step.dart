/// Step 2 of the daily planning ritual: review today's scheduled items.
///
/// Displays scheduled tasks with a due date on today.
/// - Confirm → selected for today (stays scheduled).
/// - Reschedule → opens a date picker; task moves to a future date and
///   disappears from this list.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/daily_planning_provider.dart';

class ScheduledReviewStep extends ConsumerWidget {
  const ScheduledReviewStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncItems = ref.watch(scheduledDueTodayProvider);

    return asyncItems.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Error: $err')),
      data: (items) {
        if (items.isEmpty) {
          return const _EmptyScheduled();
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          itemCount: items.length,
          separatorBuilder: (context, i) => const SizedBox(height: 8),
          itemBuilder: (context, i) => _ScheduledCard(
            todo: items[i],
            onConfirm: () => ref
                .read(dailyPlanningProvider.notifier)
                .confirmScheduledTask(items[i].id),
            onReschedule: () =>
                _pickNewDate(context, ref, items[i]),
          ),
        );
      },
    );
  }

  Future<void> _pickNewDate(
      BuildContext context, WidgetRef ref, Todo todo) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(days: 1)),
      firstDate: now.add(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'Reschedule to',
    );
    if (picked != null) {
      await ref
          .read(dailyPlanningProvider.notifier)
          .rescheduleTask(todo.id, picked);
    }
  }
}

// ---------------------------------------------------------------------------
// Scheduled task card
// ---------------------------------------------------------------------------

class _ScheduledCard extends StatelessWidget {
  const _ScheduledCard(
      {required this.todo,
      required this.onConfirm,
      required this.onReschedule});

  final Todo todo;
  final VoidCallback onConfirm;
  final VoidCallback onReschedule;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFE5E7EB)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.event_outlined,
                    size: 16, color: Color(0xFF6B7280)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    todo.title,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF1A1A2E)),
                  ),
                ),
              ],
            ),
            if (todo.timeEstimate != null) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.timer_outlined,
                      size: 12, color: Colors.grey[500]),
                  const SizedBox(width: 4),
                  Text(
                    '${todo.timeEstimate}m estimated',
                    style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onReschedule,
                    icon: const Icon(Icons.edit_calendar_outlined, size: 16),
                    label: const Text('Reschedule'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF6B7280),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onConfirm,
                    icon: const Icon(Icons.check, size: 16),
                    label: const Text('Confirm'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF16A34A),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyScheduled extends StatelessWidget {
  const _EmptyScheduled();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.event_available_outlined,
              size: 56, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text(
            'Nothing scheduled for today',
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Colors.grey[600]),
          ),
          const SizedBox(height: 6),
          Text(
            'Tap Next to continue.',
            style: TextStyle(fontSize: 14, color: Colors.grey[400]),
          ),
        ],
      ),
    );
  }
}
