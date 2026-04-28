import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/focus_session_planning_provider.dart';
import '../providers/focus_session_provider.dart';
import '../providers/focus_settings_provider.dart';
import '../providers/sprint_timer_provider.dart'
    show findBatchingCandidates, sprintTimerProvider;

class FocusScreen extends ConsumerWidget {
  const FocusScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncTasks = ref.watch(activeSessionTasksProvider);
    final currentTaskId =
        ref.watch(activeSessionProvider).asData?.value?.currentTaskId;

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 20, 8),
              child: Row(
                children: [
                  Builder(
                    builder: (ctx) => IconButton(
                      icon: const Icon(Icons.menu),
                      onPressed: () {
                        ctx.findRootAncestorStateOfType<ScaffoldState>()?.openDrawer();
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Focus',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: asyncTasks.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (err, _) => Center(child: Text('Error: $err')),
                data: (tasks) {
                  final sprintMinutes =
                      ref.watch(focusSettingsProvider).sprintDurationMinutes;
                  final withDue = tasks.where((t) => t.dueDate != null).toList()
                    ..sort((a, b) => a.dueDate!.compareTo(b.dueDate!));
                  final noDue = tasks.where((t) => t.dueDate == null).toList();
                  final sortedTasks = [...withDue, ...noDue];

                  final batchCandidates = findBatchingCandidates(
                    tasks,
                    sprintMinutes: sprintMinutes,
                  );

                  return ListView(
                    physics: const ClampingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
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
                      const SizedBox(height: 8),
                      // Batching suggestion banner.
                      if (batchCandidates.isNotEmpty)
                        _BatchSuggestionBanner(
                          candidates: batchCandidates,
                          sprintMinutes: sprintMinutes,
                        ),
                      if (sortedTasks.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            'No tasks selected — plan your day to add some!',
                            style: TextStyle(fontSize: 14, color: Colors.grey[400]),
                            textAlign: TextAlign.center,
                          ),
                        )
                      else
                        ...sortedTasks.map(
                          (t) => _TaskRow(todo: t, currentTaskId: currentTaskId),
                        ),
                      const SizedBox(height: 48),
                      FilledButton(
                        onPressed: () => _replanDay(context, ref),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFEFF6FF),
                          foregroundColor: const Color(0xFF2563EB),
                          minimumSize: const Size.fromHeight(52),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text(
                          'Plan the Day',
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(height: 32),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _replanDay(BuildContext context, WidgetRef ref) async {
    await ref.read(focusSessionPlanningProvider.notifier).reEnterPlanning();
    if (!context.mounted) return;
    context.go('/focus-session-planning');
  }
}

// ---------------------------------------------------------------------------
// Task row
// ---------------------------------------------------------------------------

class _TaskRow extends ConsumerWidget {
  const _TaskRow({required this.todo, required this.currentTaskId});
  final Todo todo;
  final String? currentTaskId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sprintMinutes =
        ref.watch(focusSettingsProvider).sprintDurationMinutes;
    final estimate = todo.timeEstimate;
    final isDone = todo.doneAt != null;
    final isCurrentTask = currentTaskId == todo.id;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () => context.push('/task/${todo.id}'),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      todo.title,
                      style: TextStyle(
                        fontSize: 16,
                        color: isDone
                            ? const Color(0xFF9CA3AF)
                            : const Color(0xFF1A1A2E),
                        fontWeight: FontWeight.w500,
                        decoration:
                            isDone ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    if (todo.dueDate != null) ...[
                      const SizedBox(height: 2),
                      Builder(builder: (_) {
                        // Storage is UTC; display the user's local calendar day.
                        final d = todo.dueDate!.toLocal();
                        return Text(
                          'Due ${d.year}-'
                          '${d.month.toString().padLeft(2, '0')}-'
                          '${d.day.toString().padLeft(2, '0')}',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF9CA3AF)),
                        );
                      }),
                    ],
                    if (estimate != null) ...[
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text(
                            estimate < 60
                                ? '${estimate}m'
                                : estimate % 60 == 0
                                    ? '${estimate ~/ 60}h'
                                    : '${estimate ~/ 60}h ${estimate % 60}m',
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF9CA3AF)),
                          ),
                          if (estimate > sprintMinutes) ...[
                            const SizedBox(width: 6),
                            Text(
                              '· ${(estimate / sprintMinutes).ceil()} sprints',
                              style: const TextStyle(
                                  fontSize: 12, color: Color(0xFF9CA3AF)),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (isDone)
            const Icon(Icons.check_circle,
                color: Color(0xFF2667B7), size: 20)
          else if (isCurrentTask)
            _StartButton(label: 'Resume', todoId: todo.id)
          else
            _StartButton(label: 'Start', todoId: todo.id),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right, color: Color(0xFF9CA3AF)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Batching suggestion banner
// ---------------------------------------------------------------------------

class _BatchSuggestionBanner extends StatefulWidget {
  const _BatchSuggestionBanner({
    required this.candidates,
    required this.sprintMinutes,
  });
  final List<Todo> candidates;
  final int sprintMinutes;

  @override
  State<_BatchSuggestionBanner> createState() => _BatchSuggestionBannerState();
}

class _BatchSuggestionBannerState extends State<_BatchSuggestionBanner> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();

    final count = widget.candidates.length;
    final total = widget.candidates.fold<int>(
        0, (sum, t) => sum + (t.timeEstimate ?? 0));

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lightbulb_outline_rounded,
              size: 18, color: Color(0xFFD97706)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Batch $count micro-tasks into one sprint',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF92400E),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$count tasks · ${total}m total — fits in one ${widget.sprintMinutes}-min sprint.',
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFFB45309)),
                ),
              ],
            ),
          ),
          Semantics(
            button: true,
            label: 'Dismiss batching suggestion',
            child: GestureDetector(
              onTap: () => setState(() => _dismissed = true),
              child: const Icon(Icons.close_rounded,
                  size: 16, color: Color(0xFFD97706)),
            ),
          ),
        ],
      ),
    );
  }
}

class _StartButton extends ConsumerWidget {
  const _StartButton({required this.label, required this.todoId});

  final String label;
  final String todoId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FilledButton(
      onPressed: () async {
        // If the sprint timer is already running for this task (e.g. we are
        // mid-break or in overtime), just navigate back to the active screen
        // rather than resetting the session.
        final sprint = ref.read(sprintTimerProvider);
        if (sprint.isActive && sprint.activeTaskId == todoId) {
          if (context.mounted) context.push('/focus/active');
          return;
        }
        // If the in-memory focus state already tracks this task, just navigate.
        if (ref.read(focusModeProvider).activeTodoId == todoId) {
          if (context.mounted) context.push('/focus/active');
          return;
        }

        await ref.read(focusModeProvider.notifier).startFocus(todoId);
        if (context.mounted) {
          context.push('/focus/active');
        }
      },
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFF2667B7),
        minimumSize: const Size(72, 36),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle:
            const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }
}
