library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../providers/daily_planning_provider.dart';

class ScheduledReviewStep extends ConsumerWidget {
  const ScheduledReviewStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncSelected = ref.watch(todaySelectedTasksProvider);

    return asyncSelected.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Error: $err')),
      data: (tasks) {
        final withDue = tasks.where((t) => t.dueDate != null).toList()
          ..sort((a, b) => a.dueDate!.compareTo(b.dueDate!));
        final scheduledNoDue = tasks
            .where((t) => t.dueDate == null && t.state == GtdState.scheduled.value)
            .toList();
        final rest = tasks
            .where((t) => t.dueDate == null && t.state != GtdState.scheduled.value)
            .toList();
        final sortedTasks = [...withDue, ...scheduledNoDue, ...rest];

        return ListView(
          physics: const ClampingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          children: [
            const Text(
              "Today's Schedule",
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1A1A2E),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey[50],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey[200]!),
              ),
              child: const Center(
                child: Text(
                  "Calendar events placeholder",
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            ),
            const SizedBox(height: 36),
            const Divider(height: 1, color: Color(0xFFF3F4F6)),
            const SizedBox(height: 36),
            const Text(
              "Today's Tasks",
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1A1A2E),
              ),
            ),
            const SizedBox(height: 16),
            if (sortedTasks.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'No tasks selected — go back and select some!',
                  style: TextStyle(fontSize: 14, color: Colors.grey[400]),
                  textAlign: TextAlign.center,
                ),
              )
            else
              ...sortedTasks.map((t) => _TaskRow(todo: t)),
            const SizedBox(height: 48),
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
            const SizedBox(height: 32),
          ],
        );
      },
    );
  }

  Future<void> _startDay(BuildContext context, WidgetRef ref) async {
    Object? startError;
    try {
      await ref.read(dailyPlanningProvider.notifier).startDay();
    } catch (e) {
      startError = e;
    }
    if (!context.mounted) return;
    if (startError != null) {
      debugPrint('Failed to start day: $startError');
      return;
    }
    context.go('/focus');
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.todo});
  final Todo todo;

  @override
  Widget build(BuildContext context) {
    final estimate = todo.timeEstimate;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.check_circle_outline,
              size: 20, color: Color(0xFF16A34A)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  todo.title,
                  style: const TextStyle(
                      fontSize: 15, color: Color(0xFF1A1A2E), fontWeight: FontWeight.w500),
                ),
                if (todo.dueDate != null)
                  Builder(builder: (_) {
                    // Storage is UTC; display the user's local calendar day.
                    final d = todo.dueDate!.toLocal();
                    return Text(
                      'Due ${d.year}-'
                      '${d.month.toString().padLeft(2, '0')}-'
                      '${d.day.toString().padLeft(2, '0')}',
                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                    );
                  }),
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
