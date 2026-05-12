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

import '../../../providers/database_provider.dart';
import '../../../providers/focus_session_planning_provider.dart';
import '../../../widgets/process_to_handlers.dart';

// ---------------------------------------------------------------------------
// Hint enum — derived from task state
// ---------------------------------------------------------------------------

enum ReclarifyHint { noNextAction, updatedSinceClarified }

/// Mirror of [TodoDao] `_needsReviewWhere`'s actionless predicate:
/// `next_action_text IS NULL OR TRIM(next_action_text) = ''`. Whitespace-only
/// values land rows in the queue, so the hint must agree (#278).
ReclarifyHint hintFor(Todo t) =>
    (t.nextActionText == null || t.nextActionText!.trim().isEmpty)
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
    final nav = state.reviewNav;

    if (!nav.isLoaded || nav.isComplete) {
      return const _AllReviewedCard();
    }

    final task = nav.current!;
    return _ReviewCard(
      key: ValueKey(task.id),
      task: task,
      hint: hintFor(task),
      previousAction: state.reviewActions[nav.index],
    );
  }
}

// ---------------------------------------------------------------------------
// Per-item review card
// ---------------------------------------------------------------------------

class _ReviewCard extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final isActionless = hint == ReclarifyHint.noNextAction;

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
          task.title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: Color(0xFF1A1A2E),
          ),
        ),

        // Notes (if any)
        if (task.notes != null && task.notes!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            task.notes!,
            style: TextStyle(fontSize: 14, color: Colors.grey[600]),
          ),
        ],

        // Current next action (if stale)
        if (!isActionless && task.nextActionText != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.arrow_forward_ios,
                  size: 12, color: Colors.grey[400]),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  task.nextActionText!,
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

        // Action buttons — defaults plus the dialog modifier on Next.
        // Stale tasks add "Still relevant" (keep with a custom label);
        // Actionless tasks omit it because defining an action is required.
        const _FieldLabel('WHAT DO YOU WANT TO DO?'),
        const SizedBox(height: 12),

        ProcessToHandlers(
          todo: task,
          include: {
            ProcessAction.nextActionDialog,
            if (!isActionless) ProcessAction.keep,
          },
          labels: const {
            ProcessAction.keep: 'Still relevant',
            ProcessAction.next: 'Update next action…',
          },
          lastAction: _toProcessAction(previousAction?.kind),
          onAfterRoute: (action) async {
            final notifier =
                ref.read(focusSessionPlanningProvider.notifier);
            if (action == ProcessAction.nextActionDialog) {
              // Blank dialog text normalises nextActionText to null and
              // leaves the task in the re-clarification queue — clear the
              // action record and stay on the same item.
              final updated =
                  await ref.read(databaseProvider).todoDao.getTodo(task.id);
              final txt = updated?.nextActionText?.trim() ?? '';
              if (txt.isEmpty) {
                notifier.clearCurrentReviewAction();
                return;
              }
              notifier.recordReviewActionAndAdvance(ReviewActionRecord(
                kind: ReviewActionKind.updateNextAction,
                nextActionText: txt,
              ));
              return;
            }
            final record = _toReviewActionRecord(action);
            if (record == null) return;
            notifier.recordReviewActionAndAdvance(record);
          },
        ),
      ],
    );
  }
}

ProcessAction? _toProcessAction(ReviewActionKind? kind) => switch (kind) {
      null => null,
      ReviewActionKind.stillRelevant => ProcessAction.keep,
      ReviewActionKind.updateNextAction => ProcessAction.nextActionDialog,
      ReviewActionKind.waitingFor => ProcessAction.waitingFor,
      ReviewActionKind.markDone => ProcessAction.done,
      ReviewActionKind.sendToSomeday => ProcessAction.someday,
      ReviewActionKind.trash => ProcessAction.trash,
    };

/// Translates a routed [ProcessAction] to the matching [ReviewActionRecord].
/// `nextActionDialog` is handled separately because it carries the dialog
/// text. `keep` records `stillRelevant`. Returns null for actions the
/// task-review surface does not produce.
ReviewActionRecord? _toReviewActionRecord(ProcessAction action) =>
    switch (action) {
      ProcessAction.keep => const ReviewActionRecord(
          kind: ReviewActionKind.stillRelevant,
        ),
      ProcessAction.next => const ReviewActionRecord(
          kind: ReviewActionKind.updateNextAction,
        ),
      ProcessAction.waitingFor =>
        const ReviewActionRecord(kind: ReviewActionKind.waitingFor),
      ProcessAction.someday =>
        const ReviewActionRecord(kind: ReviewActionKind.sendToSomeday),
      ProcessAction.done =>
        const ReviewActionRecord(kind: ReviewActionKind.markDone),
      ProcessAction.trash =>
        const ReviewActionRecord(kind: ReviewActionKind.trash),
      ProcessAction.nextActionDialog => null,
    };

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
