/// Step 1 of the daily planning ritual: Task Review (re-clarification surface).
///
/// Surfaces tasks needing re-clarification one at a time:
/// - Stale tasks: worked on in a session more recently than last clarified.
/// - Actionless tasks: no next action defined.
///
/// Context-aware action menu:
/// - Stale tasks show "Still relevant" (stamps last_clarified_at, clears stale).
/// - Actionless tasks omit "Still relevant" — defining an action is required.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/focus_session_planning_provider.dart';
import '../../../widgets/person_tag_picker.dart';

// ---------------------------------------------------------------------------
// Hint enum — derived from task state
// ---------------------------------------------------------------------------

enum ReclarifyHint { noNextAction, updatedSinceClarified }

ReclarifyHint hintFor(Todo t) => t.nextActionText == null
    ? ReclarifyHint.noNextAction
    : ReclarifyHint.updatedSinceClarified;

// ---------------------------------------------------------------------------
// Step widget
// ---------------------------------------------------------------------------

class TaskReviewStep extends ConsumerWidget {
  const TaskReviewStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(focusSessionPlanningProvider);
    final items = state.reviewItems;
    final index = state.reviewIndex;

    if (index >= items.length) {
      return const _AllReviewedCard();
    }

    final task = items[index];
    return _ReviewCard(
      key: ValueKey(task.id),
      task: task,
      hint: hintFor(task),
      previousAction: state.reviewActions[index],
    );
  }
}

// ---------------------------------------------------------------------------
// Per-item review card
// ---------------------------------------------------------------------------

class _ReviewCard extends ConsumerStatefulWidget {
  const _ReviewCard({
    super.key,
    required this.task,
    required this.hint,
    this.previousAction,
  });

  final Todo task;
  final ReclarifyHint hint;

  /// Action recorded for this index on a previous pass — drives selection
  /// affordances and pre-fills dialogs when the user navigates back.
  final ReviewActionRecord? previousAction;

  @override
  ConsumerState<_ReviewCard> createState() => _ReviewCardState();
}

class _ReviewCardState extends ConsumerState<_ReviewCard> {
  bool _busy = false;

  Future<void> _runOnce(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmRelevant() => _runOnce(() => ref
      .read(focusSessionPlanningProvider.notifier)
      .confirmReviewItemRelevant(widget.task.id));

  Future<void> _waitingFor() => _runOnce(() async {
        final preselected =
            widget.previousAction?.kind == ReviewActionKind.waitingFor
                ? widget.previousAction!.personTagIds
                : const <String>{};
        await showPersonTagPicker(
          context,
          todoId: widget.task.id,
          assignedPersonTagIds: preselected,
          requireSelection: true,
          onAfterConfirm: () => ref
              .read(focusSessionPlanningProvider.notifier)
              .markReviewItemWaitingFor(
                widget.task.id,
                isActionless: widget.hint == ReclarifyHint.noNextAction,
              ),
        );
      });

  Future<void> _updateNextAction() => _runOnce(() async {
        final initial =
            widget.previousAction?.kind == ReviewActionKind.updateNextAction
                ? (widget.previousAction!.nextActionText ?? widget.task.nextActionText ?? '')
                : (widget.task.nextActionText ?? '');
        final text = await showDialog<String>(
          context: context,
          builder: (ctx) => _NextActionDialog(
            initial: initial,
            taskTitle: widget.task.title,
          ),
        );
        if (text != null && mounted) {
          await ref
              .read(focusSessionPlanningProvider.notifier)
              .updateReviewItemNextAction(widget.task.id, text);
        }
      });

  Future<void> _markDone() => _runOnce(() => ref
      .read(focusSessionPlanningProvider.notifier)
      .markReviewItemDone(widget.task.id));

  Future<void> _sendToSomeday() => _runOnce(() => ref
      .read(focusSessionPlanningProvider.notifier)
      .deferReviewItemToSomeday(widget.task.id));

  Future<void> _trash() => _runOnce(() => ref
      .read(focusSessionPlanningProvider.notifier)
      .trashReviewItem(widget.task.id));

  @override
  Widget build(BuildContext context) {
    final isActionless = widget.hint == ReclarifyHint.noNextAction;
    final selectedKind = widget.previousAction?.kind;

    return ListView(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        // Hint badge
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isActionless
                ? const Color(0xFFFEF3C7)
                : const Color(0xFFEFF6FF),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isActionless
                  ? const Color(0xFFFDE68A)
                  : const Color(0xFFDBEAFE),
            ),
          ),
          child: Row(
            children: [
              Icon(
                isActionless
                    ? Icons.warning_amber_outlined
                    : Icons.update_outlined,
                size: 18,
                color: isActionless
                    ? const Color(0xFFD97706)
                    : const Color(0xFF2563EB),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isActionless
                      ? 'No next action defined'
                      : 'Updated since last clarified',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: isActionless
                        ? const Color(0xFF92400E)
                        : const Color(0xFF1D4ED8),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Task title
        Text(
          widget.task.title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: Color(0xFF1A1A2E),
          ),
        ),

        // Notes (if any)
        if (widget.task.notes != null && widget.task.notes!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            widget.task.notes!,
            style: TextStyle(fontSize: 14, color: Colors.grey[600]),
          ),
        ],

        // Current next action (if stale)
        if (!isActionless && widget.task.nextActionText != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.arrow_forward_ios,
                  size: 12, color: Colors.grey[400]),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  widget.task.nextActionText!,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey[600],
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ),
        ],

        const SizedBox(height: 28),

        // Action buttons
        const _FieldLabel('WHAT DO YOU WANT TO DO?'),
        const SizedBox(height: 12),

        // "Still relevant" — only for Stale tasks
        if (!isActionless) ...[
          _ActionButton(
            label: 'Still relevant',
            icon: Icons.check_circle_outline,
            color: const Color(0xFF16A34A),
            selected: selectedKind == ReviewActionKind.stillRelevant,
            onTap: _busy ? null : _confirmRelevant,
          ),
          const SizedBox(height: 8),
        ],

        _ActionButton(
          label: 'Update next action…',
          icon: Icons.edit_outlined,
          color: const Color(0xFF2563EB),
          selected: selectedKind == ReviewActionKind.updateNextAction,
          onTap: _busy ? null : _updateNextAction,
        ),
        const SizedBox(height: 8),
        _ActionButton(
          label: 'Waiting for…',
          icon: Icons.person_outlined,
          color: const Color(0xFF7C3AED),
          selected: selectedKind == ReviewActionKind.waitingFor,
          onTap: _busy ? null : _waitingFor,
        ),
        const SizedBox(height: 8),
        _ActionButton(
          label: 'Send to Someday',
          icon: Icons.star_border,
          color: const Color(0xFF6B7280),
          selected: selectedKind == ReviewActionKind.sendToSomeday,
          onTap: _busy ? null : _sendToSomeday,
        ),
        const SizedBox(height: 8),
        _ActionButton(
          label: 'Mark done',
          icon: Icons.task_alt_outlined,
          color: const Color(0xFF16A34A),
          selected: selectedKind == ReviewActionKind.markDone,
          onTap: _busy ? null : _markDone,
        ),
        const SizedBox(height: 8),
        _ActionButton(
          label: 'Trash',
          icon: Icons.delete_outline,
          color: const Color(0xFFDC2626),
          selected: selectedKind == ReviewActionKind.trash,
          onTap: _busy ? null : _trash,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// All-reviewed empty state
// ---------------------------------------------------------------------------

class _AllReviewedCard extends ConsumerStatefulWidget {
  const _AllReviewedCard();

  @override
  ConsumerState<_AllReviewedCard> createState() => _AllReviewedCardState();
}

class _AllReviewedCardState extends ConsumerState<_AllReviewedCard> {
  bool _busy = false;

  Future<void> _advance() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(focusSessionPlanningProvider.notifier).advanceStep();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.done_all_outlined, size: 56, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text(
            'All tasks reviewed!',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Tap Next to continue planning.',
            style: TextStyle(fontSize: 14, color: Colors.grey[400]),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy ? null : _advance,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              padding:
                  const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
            ),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// "Update next action" dialog
// ---------------------------------------------------------------------------

class _NextActionDialog extends StatefulWidget {
  const _NextActionDialog({required this.initial, required this.taskTitle});

  final String initial;
  final String taskTitle;

  @override
  State<_NextActionDialog> createState() => _NextActionDialogState();
}

class _NextActionDialogState extends State<_NextActionDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Update next action'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.taskTitle,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Color(0xFF6B7280)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'What\'s the next physical action?',
              border: OutlineInputBorder(),
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            maxLines: 2,
            minLines: 1,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Small widgets
// ---------------------------------------------------------------------------

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.label);
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

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
    this.selected = false,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18, color: color),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        backgroundColor: selected ? color.withValues(alpha: 0.08) : null,
        side: BorderSide(
          color: selected ? color.withValues(alpha: 0.7) : color.withValues(alpha: 0.4),
        ),
        alignment: Alignment.centerLeft,
        minimumSize: const Size.fromHeight(44),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}
