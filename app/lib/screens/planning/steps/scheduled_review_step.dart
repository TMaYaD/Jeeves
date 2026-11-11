library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../providers/focus_session_planning_provider.dart';
import '../../../widgets/outcome_row.dart';

class ScheduledReviewStep extends ConsumerWidget {
  const ScheduledReviewStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncSelected = ref.watch(focusSessionPlanningSelectedTasksProvider);

    return asyncSelected.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Error: $err')),
      data: (tasks) {
        final withDue = tasks.where((t) => t.dueDate != null).toList()
          ..sort((a, b) => a.dueDate!.compareTo(b.dueDate!));
        final noDue = tasks.where((t) => t.dueDate == null).toList();
        final sortedTasks = [...withDue, ...noDue];

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
              ...sortedTasks.map((t) => OutcomeRow(
                title: t.title,
                timeEstimateMinutes: t.timeEstimate,
                dueDate: t.dueDate,
                framed: true,
                leading: const Icon(Icons.check_circle_outline,
                    size: 20, color: Color(0xFF16A34A)),
              )),
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
      await ref.read(focusSessionPlanningProvider.notifier).startDay();
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
