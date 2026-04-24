import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/daily_planning_provider.dart';
import '../providers/focus_session_provider.dart';

enum _FocusMenuAction { planDay }

class FocusScreen extends ConsumerWidget {
  const FocusScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionDate = ref.watch(planningSessionDateProvider);
    if (sessionDate != planningToday()) {
      Future.microtask(
          () => ref.read(planningSessionDateProvider.notifier).reset());
    }

    final asyncSelected = ref.watch(todaySelectedTasksProvider);

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
              child: asyncSelected.when(
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

                  return ValueListenableBuilder<bool>(
                    valueListenable: planningCompletionNotifier,
                    builder: (context, planningDone, _) {
                      final showShutdownEntry = planningDone && sortedTasks.isNotEmpty;

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
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              const Text(
                                "Today's Tasks",
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF1A1A2E),
                                ),
                              ),
                              if (showShutdownEntry) ...[
                                const Spacer(),
                                PopupMenuButton<_FocusMenuAction>(
                                  icon: const Icon(Icons.more_vert,
                                      color: Color(0xFF6B7280)),
                                  onSelected: (action) {
                                    if (action == _FocusMenuAction.planDay) {
                                      _replanDay(context, ref);
                                    }
                                  },
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(
                                      value: _FocusMenuAction.planDay,
                                      child: Row(
                                        children: [
                                          Icon(Icons.wb_sunny_outlined,
                                              size: 18,
                                              color: Color(0xFF6B7280)),
                                          SizedBox(width: 8),
                                          Text('Re-plan'),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (planningDone && sortedTasks.isNotEmpty)
                            ...sortedTasks.map((t) => _TaskRow(todo: t))
                          else if (sortedTasks.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              child: Text(
                                planningDone
                                    ? 'All tasks cleared — have a great day!'
                                    : 'No tasks selected — plan your day to add some!',
                                style: TextStyle(
                                    fontSize: 14, color: Colors.grey[400]),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          const SizedBox(height: 48),
                          if (showShutdownEntry)
                            OutlinedButton(
                              onPressed: () => context.go('/shutdown'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFF1E3A5F),
                                backgroundColor: Colors.white,
                                side: const BorderSide(
                                    color: Color(0xFF1E3A5F), width: 1.5),
                                minimumSize: const Size.fromHeight(52),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                              ),
                              child: const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.nightlight_outlined, size: 18),
                                  SizedBox(width: 8),
                                  Text(
                                    'Begin Evening Shutdown',
                                    style: TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                            )
                          else
                            FilledButton(
                              onPressed: () => _replanDay(context, ref),
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFFEFF6FF),
                                foregroundColor: const Color(0xFF2563EB),
                                minimumSize: const Size.fromHeight(52),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                              ),
                              child: const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.wb_sunny_outlined, size: 18),
                                  SizedBox(width: 8),
                                  Text(
                                    'Plan the Day',
                                    style: TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                            ),
                          // Tasks pre-selected before today's planning (rolled over)
                          if (!planningDone && sortedTasks.isNotEmpty) ...[
                            const SizedBox(height: 24),
                            const _SectionLabel('CARRIED OVER FROM YESTERDAY'),
                            const SizedBox(height: 8),
                            ...sortedTasks.map((t) => _CarriedOverTaskRow(todo: t)),
                          ],
                          const SizedBox(height: 32),
                        ],
                      );
                    },
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
    await ref.read(dailyPlanningProvider.notifier).reEnterPlanning();
    if (!context.mounted) return;
    context.go('/planning');
  }
}

class _TaskRow extends ConsumerWidget {
  const _TaskRow({required this.todo});
  final Todo todo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final estimate = todo.timeEstimate;
    final gtdState = GtdState.fromString(todo.state);
    final isDone = gtdState == GtdState.done;
    final isInProgress = gtdState == GtdState.inProgress;

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
                      Text(
                        estimate < 60
                            ? '${estimate}m'
                            : estimate % 60 == 0
                                ? '${estimate ~/ 60}h'
                                : '${estimate ~/ 60}h ${estimate % 60}m',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF9CA3AF)),
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
          else if (isInProgress)
            _StartButton(
              label: 'Resume',
              todoId: todo.id,
              inProgressSince: todo.inProgressSince != null
                  ? DateTime.tryParse(todo.inProgressSince!)
                  : null,
            )
          else
            _StartButton(label: 'Start', todoId: todo.id),
        ],
      ),
    );
  }
}

class _StartButton extends ConsumerWidget {
  const _StartButton({
    required this.label,
    required this.todoId,
    this.inProgressSince,
  });

  final String label;
  final String todoId;

  /// Non-null only when the task is already inProgress (Resume path).
  final DateTime? inProgressSince;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FilledButton(
      onPressed: () async {
        final notifier = ref.read(focusModeProvider.notifier);
        if (inProgressSince != null) {
          // Task is already inProgress — restore session from DB timestamp.
          notifier.resumeFrom(todoId, inProgressSince!);
        } else {
          await notifier.startFocus(todoId);
        }
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

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.2,
        color: Color(0xFF9CA3AF),
      ),
    );
  }
}

/// Read-only row shown for tasks that were rolled over before today's planning.
class _CarriedOverTaskRow extends StatelessWidget {
  const _CarriedOverTaskRow({required this.todo});
  final Todo todo;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          const Icon(Icons.update_outlined,
              size: 14, color: Color(0xFFD1D5DB)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              todo.title,
              style: const TextStyle(
                fontSize: 15,
                color: Color(0xFF9CA3AF),
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
          if (todo.timeEstimate != null)
            Text(
              _fmt(todo.timeEstimate!),
              style: const TextStyle(
                  fontSize: 12, color: Color(0xFFD1D5DB)),
            ),
        ],
      ),
    );
  }

  String _fmt(int m) {
    if (m < 60) return '${m}m';
    if (m % 60 == 0) return '${m ~/ 60}h';
    return '${m ~/ 60}h ${m % 60}m';
  }
}
