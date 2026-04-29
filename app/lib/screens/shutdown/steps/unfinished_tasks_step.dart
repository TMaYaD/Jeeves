library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/evening_shutdown_provider.dart';

/// Step 1 of the shutdown ritual: resolve each unfinished task one at a time.
///
/// For every task that was planned but not completed today, the user must
/// choose one of three dispositions:
/// - Roll Over to Tomorrow → preselects the task for tomorrow's plan.
/// - Return to Next Actions → clears the daily selection; task reappears in
///   tomorrow's planning session.
/// - Defer until a later day → moves the task to Someday/Maybe.
class UnfinishedTasksStep extends ConsumerStatefulWidget {
  const UnfinishedTasksStep({super.key});

  @override
  ConsumerState<UnfinishedTasksStep> createState() =>
      _UnfinishedTasksStepState();
}

class _UnfinishedTasksStepState extends ConsumerState<UnfinishedTasksStep> {
  @override
  Widget build(BuildContext context) {
    final asyncUnfinished = ref.watch(unfinishedSelectedTodayProvider);

    if (asyncUnfinished.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (asyncUnfinished.hasError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
              const SizedBox(height: 16),
              const Text(
                'Could not load unfinished tasks',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    final unfinished = asyncUnfinished.asData!.value;
    if (unfinished.isEmpty) return const SizedBox.shrink();

    final current = unfinished.first;
    final notifier = ref.read(eveningShutdownProvider.notifier);

    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      child: _TaskResolutionCard(
        key: ValueKey(current.id),
        todo: current,
        onRollOver: () => notifier.rolloverTask(current.id),
        onReturn: () => notifier.returnToNextActions(current.id),
        onDefer: () => notifier.deferTask(current.id),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Single-task resolution card
// ---------------------------------------------------------------------------

class _TaskResolutionCard extends StatelessWidget {
  const _TaskResolutionCard({
    super.key,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Task title + time chips
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                todo.title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1A1A2E),
                ),
              ),
              if (todo.timeEstimate != null || todo.timeSpentMinutes > 0) ...[
                const SizedBox(height: 8),
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
            ],
          ),
        ),
        const SizedBox(height: 20),
        // Vertical resolution buttons
        _ResolutionButton(
          label: 'Roll Over to Tomorrow',
          subtitle: "Add to tomorrow's plan",
          icon: Icons.center_focus_strong_outlined,
          color: const Color(0xFF2563EB),
          onTap: onRollOver,
        ),
        const SizedBox(height: 10),
        _ResolutionButton(
          label: 'Return to Next Actions',
          subtitle: 'Reappear in a future planning session',
          icon: Icons.check_circle_outline,
          color: const Color(0xFF6B7280),
          onTap: onReturn,
        ),
        const SizedBox(height: 10),
        _ResolutionButton(
          label: 'Defer until a later day',
          subtitle: 'Move to Someday / Maybe',
          icon: Icons.star_border,
          color: const Color(0xFF6B7280),
          onTap: onDefer,
        ),
      ],
    );
  }

  String _fmt(int m) {
    if (m < 60) return '${m}m';
    if (m % 60 == 0) return '${m ~/ 60}h';
    return '${m ~/ 60}h ${m % 60}m';
  }
}

// ---------------------------------------------------------------------------
// Resolution button (full-width, vertical stack)
// ---------------------------------------------------------------------------

class _ResolutionButton extends StatelessWidget {
  const _ResolutionButton({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String label;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withAlpha(20),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: color.withAlpha(40),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 18, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: color.withAlpha(180),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: color.withAlpha(160)),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Time chip
// ---------------------------------------------------------------------------

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
                fontSize: 12, color: color, fontWeight: FontWeight.w500)),
      ],
    );
  }
}
