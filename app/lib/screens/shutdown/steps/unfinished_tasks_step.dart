library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/clarification_service.dart';
import '../../../providers/evening_shutdown_provider.dart';
import '../../../providers/focus_session_planning_provider.dart';
import '../../../widgets/process_to_handlers.dart';
import '../../../widgets/reclarify_prompt_sheet.dart';
import '../../../widgets/meta_chip.dart';
import '../../../widgets/outcome_review_card.dart';
import '../../../providers/task_detail_provider.dart';

/// Step 1 of the shutdown ritual: resolve each **unhandled** task one at a
/// time.
///
/// Uses a fixed snapshot loaded at step start, navigated by an integer index.
/// The snapshot holds only Outcomes with no resolution yet — anything the user
/// already Settled during the session was answered for then, and appears in the
/// summary rather than here (#694). For every remaining task, the user must
/// choose Done (which floats the session's verdict sheet) or one of three
/// dispositions:
/// - Done → records the current Action done, then the verdict sheet; the verdict
///   is written at once and the task leaves this list.
/// - Roll Over (to Tomorrow) → preselects the task in the next plan. Reads
///   "Roll Over to Tomorrow" for an ordinary shutdown, and plain "Roll Over"
///   when Daily Planning launched this shutdown ([shutdownThenPlanProvider]),
///   because the next plan is then minutes away, not tomorrow's.
/// - Return to Next → clears the daily selection; task reappears in
///   tomorrow's planning session.
/// - Defer until a later day → moves the task to Someday/Maybe.
///
/// Back navigation returns to the previous task and clears its in-memory
/// disposition so the user can re-choose. Disposition writes are deferred to
/// [EveningShutdownNotifier.closeDay]; a Done verdict is not provisional.
///
/// The "logged" chip is derived from `time_logs` via
/// [loggedMinutesByOutcomeProvider] — no Outcome row carries a total.
class UnfinishedTasksStep extends ConsumerStatefulWidget {
  const UnfinishedTasksStep({super.key});

  @override
  ConsumerState<UnfinishedTasksStep> createState() =>
      _UnfinishedTasksStepState();
}

class _UnfinishedTasksStepState extends ConsumerState<UnfinishedTasksStep> {
  bool _doneInFlight = false;

  /// Same two writes as the session screen's Done: complete the current Action,
  /// then float the verdict sheet. A dismissed sheet leaves the card as it was.
  Future<void> _done(Todo todo) async {
    if (_doneInFlight) return;
    _doneInFlight = true;
    try {
      await ref.read(clarificationServiceProvider).completeCurrentAction(todo.id);
      if (!mounted) return;
      // Ritual state follows the committed write, not the sheet's result: a
      // dismissal while the write is pending resolves the sheet to null yet
      // the verdict still lands.
      final notifier = ref.read(eveningShutdownProvider.notifier);
      await ReclarifyPromptSheet.show(
        context,
        todo,
        onVerdictCommitted: (verdict) {
          final kind = verdict.toRoutingKind();
          if (kind != null) notifier.recordVerdict(todo.id, kind);
        },
      );
    } finally {
      _doneInFlight = false;
    }
  }

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
      eveningShutdownProvider.select((s) => s.unfinishedNav),
    );

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
            // Not "All tasks completed": the list can be empty because
            // everything Settled to a non-done verdict, which is not the same
            // claim at all.
            Text(
              'Nothing left to resolve.',
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
    final dispositions = ref.watch(
      eveningShutdownProvider.select((s) => s.dispositions),
    );
    // Derived from time_logs; absent (→ 0) while the first emission is in
    // flight and for an Outcome with no stints.
    final loggedMinutes =
        ref.watch(loggedMinutesByOutcomeProvider).value?[current.id] ?? 0;

    final currentAction = ref.watch(currentActionProvider(current.id)).value;
    final launchedByDailyPlanning = ref.watch(shutdownThenPlanProvider);
    return OutcomeReviewCard(
      key: ValueKey(current.id),
      todo: current,
      currentActionText: currentAction?.actionText,
      meta: OutcomeMetaLine(
        timeEstimateMinutes: current.timeEstimate,
        timeLoggedMinutes: loggedMinutes > 0 ? loggedMinutes : null,
      ),
      actions: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ResolutionButton(
            label: 'Done',
            subtitle: 'Finished this — say where it stands',
            icon: Icons.task_alt_outlined,
            color: const Color(0xFF16A34A),
            onTap: () => _done(current),
          ),
          const SizedBox(height: 10),
          _ResolutionButton(
            label: launchedByDailyPlanning ? 'Roll Over' : 'Roll Over to Tomorrow',
            subtitle: launchedByDailyPlanning
                ? 'Add to your next plan'
                : "Add to tomorrow's plan",
            icon: Icons.center_focus_strong_outlined,
            color: const Color(0xFF2563EB),
            onTap: () => notifier.rolloverTask(current.id),
            isPreviouslySelected: dispositions[current.id] == 'rollover',
          ),
          const SizedBox(height: 10),
          _ResolutionButton(
            label: 'Return to Next',
            subtitle: 'Reappear in a future planning session',
            icon: Icons.check_circle_outline,
            color: const Color(0xFF6B7280),
            onTap: () => notifier.returnToNext(current.id),
            isPreviouslySelected: dispositions[current.id] == 'leave',
          ),
          const SizedBox(height: 10),
          _ResolutionButton(
            label: 'Defer until a later day',
            subtitle: 'Move to Someday/Maybe',
            icon: Icons.star_border,
            color: const Color(0xFF6B7280),
            onTap: () => notifier.deferTask(current.id),
            isPreviouslySelected: dispositions[current.id] == 'maybe',
          ),
        ],
      ),
    );
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
