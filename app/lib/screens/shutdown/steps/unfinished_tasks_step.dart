library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/evening_shutdown_provider.dart';

/// Step 1 of the shutdown ritual: resolve each unfinished task one at a time.
///
/// Uses a fixed snapshot loaded at step start, navigated by an integer index.
/// For every task that was planned but not completed today, the user must
/// choose one of three dispositions:
/// - Roll Over to Tomorrow → preselects the task for tomorrow's plan.
/// - Return to Next Actions → clears the daily selection; task reappears in
///   tomorrow's planning session.
/// - Defer until a later day → moves the task to Someday/Maybe.
///
/// Back navigation returns to the previous task and clears its in-memory
/// disposition so the user can re-choose. All disposition writes are deferred
/// to [EveningShutdownNotifier.closeDay].
class UnfinishedTasksStep extends ConsumerStatefulWidget {
  const UnfinishedTasksStep({super.key});

  @override
  ConsumerState<UnfinishedTasksStep> createState() =>
      _UnfinishedTasksStepState();
}

class _UnfinishedTasksStepState extends ConsumerState<UnfinishedTasksStep> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      ref.read(eveningShutdownProvider.notifier).loadUnfinishedSnapshot();
    });
  }

  @override
  Widget build(BuildContext context) {
    final nav = ref.watch(
        eveningShutdownProvider.select((s) => s.unfinishedNav));

    if (!nav.isLoaded) {
      return const Center(child: CircularProgressIndicator());
    }

    if (nav.isEmpty || nav.isComplete) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline, size: 56, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text(
              'All tasks completed today!',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Colors.grey[600],
              ),
            ),
          ],
        ),
      );
    }

    final current = nav.current!;
    final notifier = ref.read(eveningShutdownProvider.notifier);
    final dispositions =
        ref.watch(eveningShutdownProvider.select((s) => s.dispositions));

    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      child: _TaskResolutionCard(
        key: ValueKey(current.id),
        todo: current,
        lastDisposition: dispositions[current.id],
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
    this.lastDisposition,
  });

  final Todo todo;
  final VoidCallback onRollOver;
  final VoidCallback onReturn;
  final VoidCallback onDefer;

  /// The currently-recorded in-memory disposition for this task
  /// ('rollover' | 'leave' | 'maybe'), or null if no choice has been made yet.
  /// Drives the "previously selected" affordance shown on the matching button.
  final String? lastDisposition;

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
          isPreviouslySelected: lastDisposition == 'rollover',
        ),
        const SizedBox(height: 10),
        _ResolutionButton(
          label: 'Return to Next Actions',
          subtitle: 'Reappear in a future planning session',
          icon: Icons.check_circle_outline,
          color: const Color(0xFF6B7280),
          onTap: onReturn,
          isPreviouslySelected: lastDisposition == 'leave',
        ),
        const SizedBox(height: 10),
        _ResolutionButton(
          label: 'Defer until a later day',
          subtitle: 'Move to Someday / Maybe',
          icon: Icons.star_border,
          color: const Color(0xFF6B7280),
          onTap: onDefer,
          isPreviouslySelected: lastDisposition == 'maybe',
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
    this.isPreviouslySelected = false,
  });

  final String label;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  /// Renders a thicker tinted border when true, signalling that the user has
  /// previously chosen this disposition for the current task. Re-tapping the
  /// same button is idempotent; tapping a different one replaces the choice.
  final bool isPreviouslySelected;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withAlpha(isPreviouslySelected ? 40 : 20),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isPreviouslySelected ? color : Colors.transparent,
              width: isPreviouslySelected ? 2.0 : 0.0,
            ),
          ),
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
