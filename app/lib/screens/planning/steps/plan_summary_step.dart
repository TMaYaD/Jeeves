library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/focus_session_planning_provider.dart';
import '../../../widgets/outcome_peek_sheet.dart';

class PlanSummaryStep extends ConsumerStatefulWidget {
  const PlanSummaryStep({super.key});

  @override
  ConsumerState<PlanSummaryStep> createState() => _PlanSummaryStepState();
}

class _PlanSummaryStepState extends ConsumerState<PlanSummaryStep> {
  final Set<String> _selectedIds = {};

  bool get _selectionMode => _selectedIds.isNotEmpty;

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
    HapticFeedback.selectionClick();
  }

  void _enterSelectionMode(String id) {
    if (_selectedIds.contains(id)) return;
    setState(() => _selectedIds.add(id));
    HapticFeedback.selectionClick();
  }

  void _clearSelection() {
    setState(_selectedIds.clear);
  }

  void _selectAll(List<Todo> pendingTasks) {
    setState(() {
      _selectedIds
        ..clear()
        ..addAll(pendingTasks.map((t) => t.id));
    });
    HapticFeedback.selectionClick();
  }

  void _addSelectedToToday(List<Todo> pendingTasks) {
    final pendingIds = pendingTasks.map((t) => t.id).toSet();
    final notifier = ref.read(focusSessionPlanningProvider.notifier);
    // Filter against the live pending snapshot so a stale id (row deleted
    // between selection and commit) cannot be falsely reported as added.
    final committable = _selectedIds.intersection(pendingIds);
    // Commit in one state publish so the list rebuilds once, not N times.
    notifier.selectTasks(committable.toList());
    setState(_selectedIds.clear);
  }

  @override
  Widget build(BuildContext context) {
    final planningState = ref.watch(focusSessionPlanningProvider);
    final availableMinutes = planningState.availableMinutes;
    final asyncSelected = ref.watch(focusSessionPlanningSelectedTasksProvider);
    final asyncPending = ref.watch(nextForFocusSessionPlanningProvider);
    final asyncSkipped = ref.watch(skippedNextForFocusSessionPlanningProvider);

    // Gate the spinner on "no data yet", not "a reload is in flight". Riverpod
    // retains the previous value while a watched stream re-executes, so after
    // the initial load `hasValue` stays true and this list is never unmounted
    // again — Select, Skip, Undo, and multi-select all reorganise in place
    // instead of flashing a spinner that would reset the scroll offset (#459).
    if (!asyncSelected.hasValue ||
        !asyncPending.hasValue ||
        !asyncSkipped.hasValue) {
      return const Center(child: CircularProgressIndicator());
    }

    final selectedTasks = _sortTasks(asyncSelected.requireValue);
    final pendingTasks = asyncPending.requireValue;
    final skippedTasks = asyncSkipped.requireValue;

    final totalMinutes =
        selectedTasks.fold<int>(0, (sum, t) => sum + (t.timeEstimate ?? 0));
    final ratio = availableMinutes > 0
        ? totalMinutes / availableMinutes
        : double.infinity;

    final previewMinutes = _selectionMode
        ? pendingTasks
            .where((t) => _selectedIds.contains(t.id))
            .fold<int>(0, (sum, t) => sum + (t.timeEstimate ?? 0))
        : 0;

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

        if (_selectionMode)
          _MultiSelectActionBar(
            selectedCount: _selectedIds.length,
            pendingCount: pendingTasks.length,
            previewMinutes: previewMinutes,
            onClear: _clearSelection,
            onSelectAll:
                pendingTasks.isEmpty ? null : () => _selectAll(pendingTasks),
            onAddToToday: () => _addSelectedToToday(pendingTasks),
          ),

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
                        onUndo: () => _handleUndo(t),
                        onSkip: () => _handleSkip(t),
                        onPeek: _selectionMode
                            ? null
                            : () => OutcomePeekSheet.show(context, t),
                      )),
                  const SizedBox(height: 16),
                ],

                // Pending review
                if (pendingTasks.isNotEmpty) ...[
                  _SectionLabel('Pending Review (${pendingTasks.length})'),
                  const SizedBox(height: 8),
                  ...pendingTasks.map((t) => _ReviewCard(
                        todo: t,
                        onSelect: () => _handleSelect(t),
                        onSkip: () => _handleSkip(t),
                        selectionMode: _selectionMode,
                        isChecked: _selectedIds.contains(t.id),
                        onLongPress: () => _enterSelectionMode(t.id),
                        onTapInSelectionMode: () => _toggleSelection(t.id),
                        onPeek: _selectionMode
                            ? null
                            : () => OutcomePeekSheet.show(context, t),
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
                        onSelect: () => _handleSelect(t),
                        onUndo: () => _handleUndo(t),
                        onPeek: _selectionMode
                            ? null
                            : () => OutcomePeekSheet.show(context, t),
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

  void _handleSelect(Todo todo) {
    ref.read(focusSessionPlanningProvider.notifier).selectTask(todo.id);
  }

  void _handleSkip(Todo todo) {
    ref.read(focusSessionPlanningProvider.notifier).skipTask(todo.id);
  }

  void _handleUndo(Todo todo) {
    ref.read(focusSessionPlanningProvider.notifier).undoTaskReview(todo.id);
  }

  List<Todo> _sortTasks(List<Todo> tasks) {
    final withDue = tasks.where((t) => t.dueDate != null).toList()
      ..sort((a, b) => a.dueDate!.compareTo(b.dueDate!));
    final noDue = tasks.where((t) => t.dueDate == null).toList();
    return [...withDue, ...noDue];
  }

  String _capacitySummary(int count, int totalMinutes, int availableMinutes) {
    final planned = _formatMinutes(totalMinutes);
    final available = _formatMinutes(availableMinutes);
    return '$count task${count == 1 ? '' : 's'} · $planned planned of $available available';
  }
}

String _formatMinutes(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '${m}m';
  if (m == 0) return '${h}h';
  return '${h}h ${m}m';
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

/// Contextual bar shown above the Pending Review list while multi-select is
/// active. Sits inside the step (not the screen-level app bar, which is owned
/// by [FocusSessionPlanningScreen] and renders step progress).
class _MultiSelectActionBar extends StatelessWidget {
  const _MultiSelectActionBar({
    required this.selectedCount,
    required this.pendingCount,
    required this.previewMinutes,
    required this.onClear,
    required this.onSelectAll,
    required this.onAddToToday,
  });

  final int selectedCount;
  final int pendingCount;
  final int previewMinutes;
  final VoidCallback onClear;
  final VoidCallback? onSelectAll;
  final VoidCallback onAddToToday;

  @override
  Widget build(BuildContext context) {
    final allSelected = selectedCount >= pendingCount && pendingCount > 0;
    return Semantics(
      label: '$selectedCount task${selectedCount == 1 ? '' : 's'} selected',
      container: true,
      child: Material(
        color: const Color(0xFFEFF6FF),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          child: Row(
            children: [
              Tooltip(
                message: 'Clear selection',
                child: IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  color: const Color(0xFF374151),
                  onPressed: onClear,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$selectedCount selected',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                    if (previewMinutes > 0)
                      Text(
                        '+${_formatMinutes(previewMinutes)} planned',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[600],
                        ),
                      ),
                  ],
                ),
              ),
              if (onSelectAll != null && !allSelected)
                TextButton(
                  onPressed: onSelectAll,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF2563EB),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Select all'),
                ),
              const SizedBox(width: 4),
              Tooltip(
                message:
                    'Add $selectedCount task${selectedCount == 1 ? '' : 's'} to today\'s plan',
                child: FilledButton(
                  onPressed: onAddToToday,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    minimumSize: Size.zero,
                  ),
                  child: const Text('Add to Today'),
                ),
              ),
            ],
          ),
        ),
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
///
/// When [selectionMode] is true, the trailing icon slot is hidden and a
/// leading checkbox is shown instead; the whole card responds to taps via
/// [onTapInSelectionMode]. [onLongPress] is the entry point into selection
/// mode and is only meaningful on Pending Review rows.
///
/// [onPeek] — a plain tap outside selection mode opens the read-only Outcome
/// peek sheet. Callers pass `null` while multi-select is active so the card
/// carries no gesture params in-mode: on Today's Plan / Skipped rows that
/// leaves the card with no [GestureDetector] at all (tap inert, rendering and
/// the trailing action buttons untouched); Pending rows keep their in-mode
/// checkbox-toggle wiring. This is why the peek is gated at the call site
/// rather than by threading [selectionMode] here — [selectionMode] stays purely
/// a Pending-card rendering flag.
class _ReviewCard extends StatelessWidget {
  const _ReviewCard({
    required this.todo,
    this.isSelected = false,
    this.isSkipped = false,
    this.onSelect,
    this.onSkip,
    this.onUndo,
    this.selectionMode = false,
    this.isChecked = false,
    this.onLongPress,
    this.onTapInSelectionMode,
    this.onPeek,
  });

  final Todo todo;
  final bool isSelected;
  final bool isSkipped;
  final VoidCallback? onSelect;
  final VoidCallback? onSkip;
  final VoidCallback? onUndo;
  final bool selectionMode;
  final bool isChecked;
  final VoidCallback? onLongPress;
  final VoidCallback? onTapInSelectionMode;
  final VoidCallback? onPeek;

  @override
  Widget build(BuildContext context) {
    final textColor = isSkipped ? Colors.grey[500] : const Color(0xFF1A1A2E);
    final backgroundColor = isSkipped ? const Color(0xFFF9FAFB) : Colors.white;

    final card = Card(
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
            if (selectionMode)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Tooltip(
                  message: 'Select',
                  child: Checkbox(
                    value: isChecked,
                    onChanged: onTapInSelectionMode == null
                        ? null
                        : (_) => onTapInSelectionMode!(),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
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
            if (!selectionMode) ...[
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
          ],
        ),
      ),
    );

    if (onLongPress == null && onTapInSelectionMode == null && onPeek == null) {
      return card;
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: onLongPress,
      onTap: selectionMode ? onTapInSelectionMode : onPeek,
      child: card,
    );
  }

  String _energyLabel(String level) => switch (level) {
        'low' => 'Low',
        'medium' => 'Medium',
        'high' => 'High',
        _ => level,
      };
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
