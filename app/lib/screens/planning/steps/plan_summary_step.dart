library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/focus_session_planning_provider.dart';

class PlanSummaryStep extends ConsumerWidget {
  const PlanSummaryStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final planningState = ref.watch(focusSessionPlanningProvider);
    final availableMinutes = planningState.availableMinutes;
    final asyncSelected = ref.watch(focusSessionPlanningSelectedTasksProvider);
    final asyncPending = ref.watch(nextActionsForFocusSessionPlanningProvider);
    final asyncSkipped = ref.watch(skippedNextActionsForFocusSessionPlanningProvider);

    // Simple combinations of states
    if (asyncSelected.isLoading || asyncPending.isLoading || asyncSkipped.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final selectedTasks = _sortTasks(asyncSelected.asData?.value ?? []);
    final pendingTasks = asyncPending.asData?.value ?? [];
    final skippedTasks = asyncSkipped.asData?.value ?? [];

    final totalMinutes =
        selectedTasks.fold<int>(0, (sum, t) => sum + (t.timeEstimate ?? 0));
    final ratio = availableMinutes > 0
        ? totalMinutes / availableMinutes
        : double.infinity;

    return Column(
      children: [
        // --- Sticky capacity bar ---
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionLabel('Capacity'),
              const SizedBox(height: 8),
              _CapacityBar(ratio: ratio.clamp(0.0, 2.0)),
              const SizedBox(height: 6),
              Text(
                _capacitySummary(
                    selectedTasks.length, totalMinutes, availableMinutes),
                style: TextStyle(fontSize: 13, color: Colors.grey[600]),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFFF3F4F6)),

        // --- Scrollable task list ---
        Expanded(
          child: ScrollConfiguration(
            // Disable the M3 stretch (and legacy glow) overscroll indicator.
            // ClampingScrollPhysics already clamps the scroll position, but it
            // still dispatches an OverscrollNotification that would trigger the
            // StretchingOverscrollIndicator unless we opt out here.
            behavior:
                ScrollConfiguration.of(context).copyWith(overscroll: false),
            child: ListView(
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                // Today's tasks (selected)
                if (selectedTasks.isNotEmpty) ...[
                  _SectionLabel('Today\'s Plan (${selectedTasks.length})'),
                  const SizedBox(height: 8),
                  ...selectedTasks.map((t) => _ReviewCard(
                        todo: t,
                        isSelected: true,
                        onUndo: () => _handleUndo(ref, t),
                        onSkip: () => _handleSkip(ref, t),
                      )),
                  const SizedBox(height: 16),
                ],

                // Pending review
                if (pendingTasks.isNotEmpty) ...[
                  _SectionLabel('Pending Review (${pendingTasks.length})'),
                  const SizedBox(height: 8),
                  ...pendingTasks.map((t) => _ReviewCard(
                        todo: t,
                        onSelect: () => _handleSelect(ref, t),
                        onSkip: () => _handleSkip(ref, t),
                      )),
                  const SizedBox(height: 16),
                ],

                // Skipped tasks
                if (skippedTasks.isNotEmpty) ...[
                  _SectionLabel('Skipped Tasks (${skippedTasks.length})'),
                  const SizedBox(height: 8),
                  ...skippedTasks.map((t) => _ReviewCard(
                        todo: t,
                        isSkipped: true,
                        onSelect: () => _handleSelect(ref, t),
                        onUndo: () => _handleUndo(ref, t),
                      )),
                ],

                if (selectedTasks.isEmpty &&
                    pendingTasks.isEmpty &&
                    skippedTasks.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      'No tasks to review!',
                      style: TextStyle(fontSize: 14, color: Colors.grey[400]),
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _handleSelect(WidgetRef ref, Todo todo) {
    ref.read(focusSessionPlanningProvider.notifier).selectTask(todo.id);
  }

  void _handleSkip(WidgetRef ref, Todo todo) {
    ref.read(focusSessionPlanningProvider.notifier).skipTask(todo.id);
  }

  void _handleUndo(WidgetRef ref, Todo todo) {
    ref.read(focusSessionPlanningProvider.notifier).undoTaskReview(todo.id);
  }

  List<Todo> _sortTasks(List<Todo> tasks) {
    final withDue = tasks.where((t) => t.dueDate != null).toList()
      ..sort((a, b) => a.dueDate!.compareTo(b.dueDate!));
    final scheduledNoDue = tasks
        .where((t) => t.dueDate == null && t.state == GtdState.scheduled.value)
        .toList();
    final rest = tasks
        .where((t) => t.dueDate == null && t.state != GtdState.scheduled.value)
        .toList();
    return [...withDue, ...scheduledNoDue, ...rest];
  }

  String _capacitySummary(int count, int totalMinutes, int availableMinutes) {
    final planned = _formatMinutes(totalMinutes);
    final available = _formatMinutes(availableMinutes);
    return '$count task${count == 1 ? '' : 's'} · $planned planned of $available available';
  }

  String _formatMinutes(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return '${m}m';
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }
}

// ---------------------------------------------------------------------------
// Widgets
// ---------------------------------------------------------------------------

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.2,
        color: Color(0xFF9CA3AF),
      ),
    );
  }
}

class _CapacityBar extends StatelessWidget {
  const _CapacityBar({required this.ratio});

  final double ratio;

  @override
  Widget build(BuildContext context) {
    final Color barColor;
    if (ratio <= 0.8) {
      barColor = const Color(0xFF16A34A);
    } else if (ratio <= 1.0) {
      barColor = const Color(0xFFF59E0B);
    } else {
      barColor = const Color(0xFFDC2626);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(
        value: ratio.clamp(0.0, 1.0),
        minHeight: 10,
        backgroundColor: const Color(0xFFE5E7EB),
        valueColor: AlwaysStoppedAnimation<Color>(barColor),
      ),
    );
  }
}

/// Card representing a task in the plan-summary review list.
///
/// Two buttons are always shown in fixed positions so the layout never shifts:
/// - **Left slot** — the "select" action or its undo:
///   - pending & skipped → Select (check icon)
///   - selected → Undo (un-select)
/// - **Right slot** — the "skip" action or its undo:
///   - pending & selected → Skip (minus icon)
///   - skipped → Undo (un-skip)
///
/// This means "only the button that was pressed changes to Undo".
class _ReviewCard extends StatelessWidget {
  const _ReviewCard({
    required this.todo,
    this.isSelected = false,
    this.isSkipped = false,
    this.onSelect,
    this.onSkip,
    this.onUndo,
  });

  final Todo todo;
  final bool isSelected;
  final bool isSkipped;
  final VoidCallback? onSelect;
  final VoidCallback? onSkip;
  final VoidCallback? onUndo;

  @override
  Widget build(BuildContext context) {
    final textColor = isSkipped ? Colors.grey[500] : const Color(0xFF1A1A2E);
    final backgroundColor = isSkipped ? const Color(0xFFF9FAFB) : Colors.white;

    return Card(
      elevation: 0,
      color: backgroundColor,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isSkipped ? const Color(0xFFF3F4F6) : const Color(0xFFE5E7EB),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    todo.title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    children: [
                      if (todo.timeEstimate != null)
                        _Chip(
                          icon: Icons.timer_outlined,
                          label: _formatMinutes(todo.timeEstimate!),
                          color: isSkipped
                              ? Colors.grey[400]!
                              : const Color(0xFF2563EB),
                        ),
                      if (todo.energyLevel != null)
                        _Chip(
                          icon: Icons.bolt_outlined,
                          label: _energyLabel(todo.energyLevel!),
                          color: isSkipped
                              ? Colors.grey[400]!
                              : const Color(0xFF7C3AED),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Fixed two-button layout — positions never shift:
            //   pending  → [select] [skip]
            //   selected → [undo]   [skip]   ← only left changes
            //   skipped  → [select] [undo]   ← only right changes
            SizedBox(
              width: 80,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // Left slot: Select (pending/skipped) or Undo-of-select (planned)
                  if (isSelected && onUndo != null)
                    _IconBtn(
                      icon: Icons.undo,
                      color: const Color(0xFF6B7280),
                      tooltip: 'Remove from today',
                      onTap: onUndo!,
                    )
                  else if (!isSelected && onSelect != null)
                    _IconBtn(
                      icon: Icons.check_circle_outline,
                      color: const Color(0xFF16A34A),
                      tooltip: 'Select for today',
                      onTap: onSelect!,
                    ),
                  // Right slot: Skip (pending/planned) or Undo-of-skip (skipped)
                  if (isSkipped && onUndo != null)
                    _IconBtn(
                      icon: Icons.undo,
                      color: const Color(0xFF6B7280),
                      tooltip: 'Un-skip',
                      onTap: onUndo!,
                    )
                  else if (!isSkipped && onSkip != null)
                    _IconBtn(
                      icon: Icons.remove_circle_outline,
                      color: const Color(0xFF6B7280),
                      tooltip: 'Skip for today',
                      onTap: onSkip!,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _energyLabel(String level) => switch (level) {
        'low' => 'Low',
        'medium' => 'Medium',
        'high' => 'High',
        _ => level,
      };

  String _formatMinutes(int m) {
    if (m < 60) return '${m}m';
    if (m % 60 == 0) return '${m ~/ 60}h';
    return '${m ~/ 60}h ${m % 60}m';
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
        const SizedBox(width: 2),
        Text(label,
            style: TextStyle(
                fontSize: 12, color: color, fontWeight: FontWeight.w500)),
      ],
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Use InkWell + Padding instead of IconButton to avoid M3's 48px minimum
    // touch-target enforcement, which caused overflow in the fixed-width button
    // slot (2 × 48px = 96px > 80px SizedBox).
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, color: color, size: 22),
        ),
      ),
    );
  }
}
