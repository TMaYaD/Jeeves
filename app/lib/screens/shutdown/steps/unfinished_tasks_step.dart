library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/evening_shutdown_provider.dart';

/// Step 1 of the shutdown ritual: resolve each unfinished task.
///
/// For every task that was planned but not completed today, the user must
/// choose one of three dispositions:
/// - Roll Over → preselects the task for tomorrow's plan.
/// - Return → clears the daily selection; task reappears in tomorrow's planning.
/// - Defer → moves the task to Someday/Maybe.
class UnfinishedTasksStep extends ConsumerWidget {
  const UnfinishedTasksStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncUnfinished = ref.watch(unfinishedSelectedTodayProvider);

    if (asyncUnfinished.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final unfinished = asyncUnfinished.asData?.value ?? [];

    if (unfinished.isEmpty) {
      return const _AllResolved();
    }

    return Column(
      children: [
        _Header(remaining: unfinished.length),
        const Divider(height: 1, color: Color(0xFFF3F4F6)),
        Expanded(
          child: ScrollConfiguration(
            behavior:
                ScrollConfiguration.of(context).copyWith(overscroll: false),
            child: ListView(
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: unfinished
                  .map((t) => _UnfinishedTaskCard(
                        todo: t,
                        onRollOver: () => ref
                            .read(eveningShutdownProvider.notifier)
                            .rolloverTask(t.id),
                        onReturn: () => ref
                            .read(eveningShutdownProvider.notifier)
                            .returnToNextActions(t.id),
                        onDefer: () => ref
                            .read(eveningShutdownProvider.notifier)
                            .deferTask(t.id),
                      ))
                  .toList(),
            ),
          ),
        ),
      ],
    );
  }
}

class _AllResolved extends StatelessWidget {
  const _AllResolved();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.task_alt, size: 56, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text(
              'All tasks resolved',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: Colors.grey[500],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'No unfinished tasks from today\'s plan.',
              style: TextStyle(fontSize: 13, color: Colors.grey[400]),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.remaining});

  final int remaining;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFFFF7ED),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          const Icon(Icons.pending_actions_outlined,
              size: 18, color: Color(0xFFD97706)),
          const SizedBox(width: 8),
          Text(
            '$remaining unfinished task${remaining == 1 ? '' : 's'} — each needs a resolution',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Color(0xFF92400E),
            ),
          ),
        ],
      ),
    );
  }
}

class _UnfinishedTaskCard extends StatelessWidget {
  const _UnfinishedTaskCard({
    required this.todo,
    required this.onRollOver,
    required this.onReturn,
    required this.onDefer,
  });

  final Todo todo;
  final VoidCallback onRollOver;
  final VoidCallback onReturn;
  final VoidCallback onDefer;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFE5E7EB)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              todo.title,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: Color(0xFF1A1A2E),
              ),
            ),
            if (todo.timeEstimate != null || todo.timeSpentMinutes > 0) ...[
              const SizedBox(height: 4),
              Wrap(
                spacing: 12,
                children: [
                  if (todo.timeEstimate != null)
                    _Chip(
                      icon: Icons.timer_outlined,
                      label: 'Est ${_fmt(todo.timeEstimate!)}',
                      color: const Color(0xFF2563EB),
                    ),
                  if (todo.timeSpentMinutes > 0)
                    _Chip(
                      icon: Icons.access_time,
                      label: '${_fmt(todo.timeSpentMinutes)} logged',
                      color: const Color(0xFF7C3AED),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _ResolutionButton(
                    label: 'Roll Over',
                    icon: Icons.arrow_forward,
                    color: const Color(0xFF2563EB),
                    onTap: onRollOver,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ResolutionButton(
                    label: 'Return',
                    icon: Icons.undo,
                    color: const Color(0xFF6B7280),
                    onTap: onReturn,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ResolutionButton(
                    label: 'Defer',
                    icon: Icons.star_border,
                    color: const Color(0xFF9CA3AF),
                    onTap: onDefer,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(int m) {
    if (m < 60) return '${m}m';
    if (m % 60 == 0) return '${m ~/ 60}h';
    return '${m ~/ 60}h ${m % 60}m';
  }
}

class _ResolutionButton extends StatelessWidget {
  const _ResolutionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withAlpha(20),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 3),
        Text(label,
            style: TextStyle(
                fontSize: 12,
                color: color,
                fontWeight: FontWeight.w500)),
      ],
    );
  }
}
