import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/focus_session_planning_provider.dart';
import '../../providers/sprint_provider.dart';
import '../../utils/time_format.dart';

/// Mandatory interstitial shown when a 20-minute sprint expires.
///
/// Cannot be dismissed without choosing an action.  Displays a spillover
/// matrix so the user understands how extending affects the rest of their day.
class SprintResolutionDialog extends ConsumerStatefulWidget {
  const SprintResolutionDialog({super.key, required this.task});

  final Todo task;

  @override
  ConsumerState<SprintResolutionDialog> createState() =>
      _SprintResolutionDialogState();
}

class _SprintResolutionDialogState
    extends ConsumerState<SprintResolutionDialog> {
  bool _showingSpillover = false;
  String? _puntedTaskId;
  bool _submitting = false;

  @override
  Widget build(BuildContext context) {
    final sprintState = ref.watch(sprintProvider);
    final todayTasks = ref.watch(focusSessionPlanningSelectedTasksProvider).value ?? [];

    final otherTasks = todayTasks
        .where((t) =>
            t.id != widget.task.id &&
            t.state != GtdState.done.value &&
            t.state != GtdState.inProgress.value)
        .toList();

    final spentMinutes = _spentMinutes(widget.task, sprintState.sprintCount + 1);

    return PopScope(
      canPop: false,
      child: AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
        contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF3C7),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Sprint ${sprintState.sprintCount + 1} Complete',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFD97706),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              widget.task.title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1A1A2E),
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            _TimeSpentRow(
              spentMinutes: spentMinutes,
              estimateMinutes: widget.task.timeEstimate,
            ),
          ],
        ),
        content: _showingSpillover
            ? _SpilloverMatrix(
                tasks: otherTasks,
                puntedTaskId: _puntedTaskId,
                onPunt: (taskId) => setState(() => _puntedTaskId = taskId),
              )
            : const _ResolutionHint(),
        actions: _showingSpillover
            ? [
                _buildOutlineButton(
                  context,
                  label: 'Back',
                  onPressed: () =>
                      setState(() => _showingSpillover = false),
                ),
                _buildFilledButton(
                  context,
                  label: 'Extend & Continue',
                  color: const Color(0xFF2563EB),
                  onPressed: () => _handleExtend(context),
                ),
              ]
            : [
                _buildOutlineButton(
                  context,
                  label: 'Defer',
                  onPressed: () => _handleDefer(context),
                ),
                _buildOutlineButton(
                  context,
                  label: 'Extend',
                  onPressed: () =>
                      setState(() => _showingSpillover = true),
                ),
                _buildFilledButton(
                  context,
                  label: 'Complete',
                  color: const Color(0xFF16A34A),
                  onPressed: () => _handleComplete(context),
                ),
              ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Handlers
  // ---------------------------------------------------------------------------

  Future<void> _handleComplete(BuildContext context) async {
    await ref.read(sprintProvider.notifier).resolveComplete();
    if (context.mounted) Navigator.of(context).pop();
  }

  Future<void> _handleExtend(BuildContext context) async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      Todo? punted;
      if (_puntedTaskId != null) {
        final todayTasks = ref.read(focusSessionPlanningSelectedTasksProvider).value ?? [];
        punted = todayTasks.where((t) => t.id == _puntedTaskId).firstOrNull;
      }
      await ref.read(sprintProvider.notifier).extendWithPunt(punted);
      if (context.mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _handleDefer(BuildContext context) async {
    await ref.read(sprintProvider.notifier).resolveDefer();
    if (context.mounted) Navigator.of(context).pop();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  int _spentMinutes(Todo task, int sprintCount) {
    final alreadyLogged = task.timeSpentMinutes;
    return alreadyLogged + (sprintCount * (kSprintDurationSeconds ~/ 60));
  }

  Widget _buildFilledButton(
    BuildContext context, {
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: color,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      onPressed: onPressed,
      child: Text(label,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
    );
  }

  Widget _buildOutlineButton(
    BuildContext context, {
    required String label,
    required VoidCallback onPressed,
  }) {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        side: const BorderSide(color: Color(0xFFD1D5DB)),
      ),
      onPressed: onPressed,
      child: Text(label,
          style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Color(0xFF374151))),
    );
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets
// ---------------------------------------------------------------------------

class _TimeSpentRow extends StatelessWidget {
  const _TimeSpentRow({required this.spentMinutes, this.estimateMinutes});

  final int spentMinutes;
  final int? estimateMinutes;

  @override
  Widget build(BuildContext context) {
    final spentLabel = formatMinutes(spentMinutes);
    final estimateLabel = estimateMinutes != null ? formatMinutes(estimateMinutes!) : null;

    return Text(
      estimateLabel != null
          ? '$spentLabel / $estimateLabel spent'
          : '$spentLabel spent',
      style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
    );
  }

}

class _ResolutionHint extends StatelessWidget {
  const _ResolutionHint();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _HintRow(
            icon: Icons.check_circle_outline,
            color: const Color(0xFF16A34A),
            label: 'Complete',
            description: 'Log time and mark done.',
          ),
          const SizedBox(height: 10),
          _HintRow(
            icon: Icons.add_circle_outline,
            color: const Color(0xFF2563EB),
            label: 'Extend',
            description: 'Add another 20-min block. Review spillover.',
          ),
          const SizedBox(height: 10),
          _HintRow(
            icon: Icons.pause_circle_outline,
            color: const Color(0xFF9CA3AF),
            label: 'Defer',
            description: 'Log partial time and park in Next Actions.',
          ),
        ],
      ),
    );
  }
}

class _HintRow extends StatelessWidget {
  const _HintRow({
    required this.icon,
    required this.color,
    required this.label,
    required this.description,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: color)),
              Text(description,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF6B7280))),
            ],
          ),
        ),
      ],
    );
  }
}

/// Visual display of how adding another sprint affects the remaining day plan.
class _SpilloverMatrix extends StatelessWidget {
  const _SpilloverMatrix({
    required this.tasks,
    required this.puntedTaskId,
    required this.onPunt,
  });

  final List<Todo> tasks;
  final String? puntedTaskId;
  final ValueChanged<String?> onPunt;

  @override
  Widget build(BuildContext context) {
    if (tasks.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text(
          'No other tasks scheduled today — extending won\'t affect your plan.',
          style: TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
        ),
      );
    }

    final totalEstimate =
        tasks.fold<int>(0, (sum, t) => sum + (t.timeEstimate ?? 0));

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Extending adds 20 min. Select a task to punt from today:',
          style: TextStyle(fontSize: 13, color: Color(0xFF374151)),
        ),
        const SizedBox(height: 4),
        Text(
          '${tasks.length} remaining tasks · ${formatMinutes(totalEstimate)} estimated',
          style:
              const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
        ),
        const SizedBox(height: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: tasks.length,
            separatorBuilder: (context, index) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final task = tasks[i];
              final isPunted = task.id == puntedTaskId;
              return InkWell(
                onTap: () => onPunt(isPunted ? null : task.id),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      Icon(
                        isPunted
                            ? Icons.remove_circle
                            : Icons.remove_circle_outline,
                        color: isPunted
                            ? const Color(0xFFDC2626)
                            : const Color(0xFFD1D5DB),
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          task.title,
                          style: TextStyle(
                            fontSize: 13,
                            color: isPunted
                                ? const Color(0xFF9CA3AF)
                                : const Color(0xFF1A1A2E),
                            decoration: isPunted
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (task.timeEstimate != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          formatMinutes(task.timeEstimate!),
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xFF9CA3AF)),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        if (puntedTaskId == null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Tap a task to remove it from today.',
              style: TextStyle(
                  fontSize: 11, color: Colors.amber.shade700),
            ),
          ),
      ],
    );
  }

}
