/// Step 2 of the daily planning ritual: Task Review (re-clarification surface).
///
/// Surfaces tasks needing re-clarification one at a time:
/// - Stale tasks: worked on in a session more recently than last clarified.
/// - Actionless tasks: no current Action (excluding delegated tasks).
///
/// Context-aware action menu:
/// - Stale tasks without a delegate show "Still relevant" (stamps
///   last_clarified_at, clears stale).
/// - Stale delegated tasks show "Still waiting" (same write, waiting-for copy).
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

enum ReclarifyHint {
  noNextAction,
  updatedSinceClarified,
  staleWaitingFor,
}

/// Returns true when [t]'s session timestamps mark it as stale: a session
/// closed after the last clarification stamp.
///
/// This mirrors only the **session-history** half of `_needsReviewWhere`'s
/// widened Stale branch. The other half — an Action completed after the last
/// clarification (ADR-0001 story 4) — is deliberately not mirrored: a
/// termination-surfaced Outcome is by construction Actionless, and [hintFor]
/// already renders Actionless as [ReclarifyHint.noNextAction], which is the
/// accurate, actionable prompt after finishing an Action. Plumbing termination
/// timestamps into the planning snapshot would buy no better hint.
bool isStaleReclarification(Todo t) =>
    t.lastNextActionCompletionAt != null &&
    (t.lastClarifiedAt == null ||
        t.lastClarifiedAt!.isBefore(t.lastNextActionCompletionAt!));

/// Mirror of [TodoDao] `_needsReviewWhere`'s actionless predicate: the Outcome
/// has no `actions` row with `role='current'` (ADR-0001 story 3). Absence of a
/// [currentActionText] *is* Actionless — the DAO predicate and this hint read
/// the same evidence, so they cannot disagree.
///
/// [currentActionText], [hasPersonTag] and [isStale] are computed by the caller
/// (the widget reads the Action text from
/// [FocusSessionPlanningState.reviewActionTexts], person tags from
/// `reviewPersonTags`, and stale from [isStaleReclarification]). Keeping the
/// helper pure makes it trivially unit-testable.
ReclarifyHint hintFor(
  Todo t, {
  required bool hasPersonTag,
  required bool isStale,
  String? currentActionText,
}) {
  if (isStale && hasPersonTag) return ReclarifyHint.staleWaitingFor;
  if (currentActionText == null || currentActionText.trim().isEmpty) {
    return ReclarifyHint.noNextAction;
  }
  return ReclarifyHint.updatedSinceClarified;
}

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
    final personTags = state.reviewPersonTags[task.id] ?? const <Tag>[];
    final currentActionText = state.reviewActionTexts[task.id];
    return _ReviewCard(
      key: ValueKey(task.id),
      task: task,
      hint: hintFor(
        task,
        hasPersonTag: personTags.isNotEmpty,
        isStale: isStaleReclarification(task),
        currentActionText: currentActionText,
      ),
      personTags: personTags,
      currentActionText: currentActionText,
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
    this.personTags = const [],
    this.currentActionText,
    this.previousAction,
  });

  final Todo task;
  final ReclarifyHint hint;

  /// Text of [task]'s current Action, or null when it is Actionless. Renders
  /// under the title and prefills the "Update next action…" dialog.
  final String? currentActionText;

  /// Person-typed tags assigned to [task]. Drives the delegate name(s) in
  /// the [ReclarifyHint.staleWaitingFor] badge.
  final List<Tag> personTags;

  /// Action recorded for this index on a previous pass — drives selection
  /// affordances and pre-fills dialogs when the user navigates back.
  final ReviewActionRecord? previousAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isActionless = hint == ReclarifyHint.noNextAction;
    final isWaitingFor = hint == ReclarifyHint.staleWaitingFor;
    final showKeep = !isActionless;

    final badgeBg = isActionless
        ? const Color(0xFFFEF3C7)
        : const Color(0xFFEFF6FF);
    final badgeBorder = isActionless
        ? const Color(0xFFFDE68A)
        : const Color(0xFFDBEAFE);
    final badgeIconColor = isActionless
        ? const Color(0xFFD97706)
        : const Color(0xFF2563EB);
    final badgeTextColor = isActionless
        ? const Color(0xFF92400E)
        : const Color(0xFF1D4ED8);
    final badgeIcon = switch (hint) {
      ReclarifyHint.noNextAction => Icons.warning_amber_outlined,
      ReclarifyHint.updatedSinceClarified => Icons.update_outlined,
      ReclarifyHint.staleWaitingFor => Icons.person_outline,
    };
    final badgeText = switch (hint) {
      ReclarifyHint.noNextAction => 'No next action defined',
      ReclarifyHint.updatedSinceClarified => 'Updated since last clarified',
      ReclarifyHint.staleWaitingFor =>
        'Waiting for ${personTags.map((t) => t.name).join(', ')} — still waiting?',
    };

    return ListView(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        // Hint badge
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: badgeBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: badgeBorder),
          ),
          child: Row(
            children: [
              Icon(badgeIcon, size: 18, color: badgeIconColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  badgeText,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: badgeTextColor,
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

        // Current Action (if present)
        if (!isActionless && currentActionText != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.arrow_forward_ios,
                  size: 12, color: Colors.grey[400]),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  currentActionText!,
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

        // Action buttons — defaults (which include the on-by-default dialog
        // modifier on Next). Stale tasks add a "keep" variant (label depends
        // on whether the task is delegated); Actionless tasks omit it because
        // defining an action is required.
        const _FieldLabel('WHAT DO YOU WANT TO DO?'),
        const SizedBox(height: 12),

        ProcessToHandlers(
          subject: OutcomeSubject(task, currentActionText: currentActionText),
          include: {
            if (showKeep) ProcessAction.keep,
          },
          labels: {
            ProcessAction.keep:
                isWaitingFor ? 'Still waiting' : 'Still relevant',
            // "Update" only when there is a current Action to update; an
            // Actionless card is *setting* the first one. Matches the dialog's
            // own "Update next action" / "Set next action" split.
            ProcessAction.next: (currentActionText != null &&
                    currentActionText!.trim().isNotEmpty)
                ? 'Update next action…'
                : 'Set next action…',
          },
          lastAction: _toProcessAction(previousAction?.kind),
          onAfterRoute: (action) async {
            final notifier =
                ref.read(focusSessionPlanningProvider.notifier);
            if (action == ProcessAction.nextActionDialog) {
              // The route has landed by the time this fires — a blank save
              // falls back to the Outcome's title rather than skipping the
              // write — so the only job left is to read the phrase back for
              // the in-session record and advance.
              final current = await ref
                  .read(databaseProvider)
                  .actionDao
                  .getCurrentAction(task.id);
              notifier.recordReviewActionAndAdvance(ReviewActionRecord(
                kind: ReviewActionKind.updateNextAction,
                actionText: current?.actionText.trim(),
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
      // `completeCapture` is a Capture verdict; this surface reviews Outcomes
      // and never offers it.
      ProcessAction.nextActionDialog ||
      ProcessAction.reclarify ||
      ProcessAction.completeCapture =>
        null,
    };

// ---------------------------------------------------------------------------
// All-reviewed empty state
// ---------------------------------------------------------------------------

class _AllReviewedCard extends StatelessWidget {
  const _AllReviewedCard();

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
