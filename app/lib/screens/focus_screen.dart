import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../database/gtd_database.dart' show Todo;
import '../providers/daily_planning_provider.dart';
import '../providers/focus_session_provider.dart';
import '../providers/sprint_provider.dart';
import 'focus/sprint_resolution_dialog.dart';

class FocusScreen extends ConsumerWidget {
  const FocusScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncSelected = ref.watch(todaySelectedTasksProvider);
    final sprintState = ref.watch(sprintProvider);

    // Show mandatory resolution dialog when a sprint expires.
    ref.listen(sprintProvider, (prev, next) {
      if (next.phase == SprintPhase.expired &&
          next.activeTask != null &&
          (prev?.phase != SprintPhase.expired)) {
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => SprintResolutionDialog(task: next.activeTask!),
        );
      }
    });

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
                  const Spacer(),
                  if (sprintState.phase == SprintPhase.running ||
                      sprintState.phase == SprintPhase.onBreak)
                    _SprintCountdown(sprintState: sprintState),
                ],
              ),
            ),
            if (sprintState.phase == SprintPhase.onBreak)
              _BreakBanner(
                remainingSeconds: sprintState.remainingSeconds,
                onEnd: () => ref.read(sprintProvider.notifier).endBreak(),
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
                        ...sortedTasks.map((t) => _TaskRow(todo: t)),
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
    await ref.read(dailyPlanningProvider.notifier).reEnterPlanning();
    if (!context.mounted) return;
    context.go('/planning');
  }
}

// ---------------------------------------------------------------------------
// Sprint countdown chip shown in the app bar
// ---------------------------------------------------------------------------

class _SprintCountdown extends StatelessWidget {
  const _SprintCountdown({required this.sprintState});

  final SprintState sprintState;

  @override
  Widget build(BuildContext context) {
    final isBreak = sprintState.phase == SprintPhase.onBreak;
    final seconds = sprintState.remainingSeconds;
    final mm = (seconds ~/ 60).toString().padLeft(2, '0');
    final ss = (seconds % 60).toString().padLeft(2, '0');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isBreak
            ? const Color(0xFFDCFCE7)
            : const Color(0xFFFEF3C7),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isBreak ? Icons.coffee : Icons.timer,
            size: 14,
            color: isBreak
                ? const Color(0xFF16A34A)
                : const Color(0xFFD97706),
          ),
          const SizedBox(width: 4),
          Text(
            '$mm:$ss',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: isBreak
                  ? const Color(0xFF16A34A)
                  : const Color(0xFFD97706),
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Break banner
// ---------------------------------------------------------------------------

class _BreakBanner extends StatelessWidget {
  const _BreakBanner({
    required this.remainingSeconds,
    required this.onEnd,
  });

  final int remainingSeconds;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    final mm = (remainingSeconds ~/ 60).toString().padLeft(2, '0');
    final ss = (remainingSeconds % 60).toString().padLeft(2, '0');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      color: const Color(0xFFDCFCE7),
      child: Row(
        children: [
          const Icon(Icons.coffee, size: 16, color: Color(0xFF16A34A)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Break time — $mm:$ss remaining',
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF15803D)),
            ),
          ),
          TextButton(
            onPressed: onEnd,
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF15803D),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: const Text('Skip Break',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Task row with sprint controls
// ---------------------------------------------------------------------------

class _TaskRow extends ConsumerWidget {
  const _TaskRow({required this.todo});

  final Todo todo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sprintState = ref.watch(sprintProvider);
    final estimate = todo.timeEstimate;
    final isActive = sprintState.activeTask?.id == todo.id;
    final isRunning = isActive && sprintState.phase == SprintPhase.running;
    final isDone = todo.state == 'done';
    final sprintCanStart = !isDone &&
        sprintState.phase == SprintPhase.idle &&
        todo.state != 'in_progress';

    return InkWell(
      onTap: () => context.push('/task/${todo.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (isRunning)
                        Container(
                          width: 8,
                          height: 8,
                          margin: const EdgeInsets.only(right: 6),
                          decoration: const BoxDecoration(
                            color: Color(0xFFD97706),
                            shape: BoxShape.circle,
                          ),
                        ),
                      Expanded(
                        child: Text(
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
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (todo.dueDate != null) ...[
                        Text(
                          'Due ${todo.dueDate!.year}-'
                          '${todo.dueDate!.month.toString().padLeft(2, '0')}-'
                          '${todo.dueDate!.day.toString().padLeft(2, '0')}',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF9CA3AF)),
                        ),
                        if (estimate != null) const Text(' · ', style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
                      ],
                      if (estimate != null)
                        Text(
                          _fmtEstimate(estimate),
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF9CA3AF)),
                        ),
                      if (todo.timeSpentMinutes > 0) ...[
                        const Text(' · ', style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
                        Text(
                          '${_fmtEstimate(todo.timeSpentMinutes)} spent',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF6B7280)),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (sprintCanStart)
              _StartSprintButton(todo: todo)
            else if (isRunning)
              const Icon(Icons.timer, size: 20, color: Color(0xFFD97706))
            else
              const Icon(Icons.chevron_right, color: Color(0xFF9CA3AF)),
          ],
        ),
      ),
    );
  }

  String _fmtEstimate(int minutes) {
    if (minutes < 60) return '${minutes}m';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }
}

class _StartSprintButton extends ConsumerWidget {
  const _StartSprintButton({required this.todo});

  final Todo todo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: () => ref.read(sprintProvider.notifier).startSprint(todo),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF3C7),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFFDE68A)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.play_arrow, size: 14, color: Color(0xFFD97706)),
            SizedBox(width: 4),
            Text(
              'Sprint',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFFD97706),
              ),
            ),
          ],
        ),
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
