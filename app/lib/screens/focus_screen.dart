import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/ritual.dart';
import '../providers/database_provider.dart';
import '../providers/focus_session_planning_provider.dart';
import '../providers/focus_session_provider.dart';
import '../providers/focus_settings_provider.dart';
import '../providers/sprint_timer_provider.dart'
    show findBatchingCandidates, sprintTimerProvider;
import '../widgets/meta_chip.dart';
import '../widgets/nudge_banner.dart'
    show InboxTooFullHead, NudgeEmptyState, RitualHead, nudgeSurfaceHeadProvider;
import '../widgets/outcome_row.dart';

class FocusScreen extends ConsumerWidget {
  const FocusScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncTasks = ref.watch(activeSessionTasksProvider);
    final activeSession = ref.watch(activeSessionProvider).asData?.value;
    final currentTaskId = activeSession?.currentTaskId;
    // Which Plan members the user has already answered for this session
    // (issue #693). Absent from the map == not Settled, and the map is empty
    // until the first emission lands — so nothing is ever struck off
    // speculatively. Completion is *not* left waiting on it: the row keeps
    // striking off on `doneAt` alone (see [_focusOutcomeRow]), which is what it did
    // before #693 and what AC4 preserves.
    final settlements = ref.watch(activeSessionSettlementsProvider).value ??
        const <String, SessionSettlement>{};
    // The session's Review surface (Plan plus anything engaged off-Plan). Null
    // until the stream first emits: an unknown surface must never read as an
    // empty one, or the first frame would offer "End Session" past an
    // unfinished Outcome (#885).
    final reviewSurface = ref.watch(activeSessionReviewSurfaceProvider).value;

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: asyncTasks.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (err, _) => Center(child: Text('Error: $err')),
                data: (tasks) {
                  final sprintMinutes =
                      ref.watch(focusSettingsProvider).sprintDurationMinutes;
                  final withDue = tasks.where((t) => t.dueDate != null).toList()
                    ..sort((a, b) => a.dueDate!.compareTo(b.dueDate!));
                  final noDue = tasks.where((t) => t.dueDate == null).toList();
                  final sortedTasks = [...withDue, ...noDue];

                  final batchCandidates = findBatchingCandidates(
                    tasks,
                    sprintMinutes: sprintMinutes,
                  );

                  // Planning-done derives from persistent session data: an
                  // open FocusSession exists (ADR-0020). This survives process
                  // death, so the "closed / carried over after idle" misreport
                  // (issue #460) becomes unreproducible.
                  final planningDone = activeSession != null;
                  // The "Begin Evening Shutdown" entry is shown once the user
                  // is in an open focus session (its Plan may be empty).
                  // Derived from the shared provider so the shutdown callout
                  // and the title bar's Re-plan action can't drift (#499).
                  final showShutdownEntry =
                      ref.watch(hasOpenSessionProvider);
                  // Tasks carried over ('rollover') from the last closed
                  // session — only while no session is open.
                  final carriedOver = planningDone
                      ? const <Todo>[]
                      : (ref
                              .watch(lastClosedSessionRolloverTasksProvider)
                              .value ??
                          const <Todo>[]);
                  // The nudge that holds the Today's Tasks empty state: Inbox
                  // too full, the Weekly Review or Daily Planning, while no
                  // open session carries tasks. Evening Shutdown and no head
                  // keep the existing content.
                  final surfaceHead = ref.watch(nudgeSurfaceHeadProvider);
                  final nudgeHead = sortedTasks.isEmpty &&
                          (surfaceHead is InboxTooFullHead ||
                              (surfaceHead is RitualHead &&
                                  surfaceHead.ritual !=
                                      RitualId.eveningShutdown))
                      ? surfaceHead
                      : null;
                  return ListView(
                        physics: const ClampingScrollPhysics(),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 8),
                        children: [
                          const Text(
                            "Today's Schedule",
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF1A1A2E),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.grey[50],
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.grey[200]!),
                            ),
                            child: const Center(
                              child: Text(
                                "Calendar events placeholder",
                                style: TextStyle(color: Colors.grey),
                              ),
                            ),
                          ),
                          const SizedBox(height: 36),
                          const Divider(height: 1, color: Color(0xFFF3F4F6)),
                          const SizedBox(height: 36),
                          // Re-plan lives in the shared title bar's page-action
                          // slot now (AppShell, #499), not in a bespoke ⋮ here.
                          const Text(
                            "Today's Tasks",
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF1A1A2E),
                            ),
                          ),
                          const SizedBox(height: 8),
                          // Batching suggestion banner.
                          if (planningDone &&
                              sortedTasks.isNotEmpty &&
                              batchCandidates.isNotEmpty)
                            _BatchSuggestionBanner(
                              candidates: batchCandidates,
                              sprintMinutes: sprintMinutes,
                            ),
                          if (planningDone && sortedTasks.isNotEmpty)
                            ...sortedTasks.map(
                              (t) => _focusOutcomeRow(
                                context,
                                sprintMinutes: sprintMinutes,
                                todo: t,
                                currentTaskId: currentTaskId,
                                settlement: settlements[t.id],
                              ),
                            )
                          else if (sortedTasks.isEmpty && nudgeHead != null)
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 16),
                              child: NudgeEmptyState(head: nudgeHead),
                            )
                          else if (sortedTasks.isEmpty)
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 16),
                              child: Text(
                                planningDone
                                    ? 'All tasks cleared — have a great day!'
                                    : 'No tasks selected — plan your day to add some!',
                                style: TextStyle(
                                    fontSize: 14, color: Colors.grey[400]),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          const SizedBox(height: 48),
                          // showShutdownEntry now comes from an opaque provider
                          // bool, so it no longer promotes [activeSession] to
                          // non-null here the way the old `planningDone && …`
                          // local derivation did. The explicit null-check
                          // restores promotion for [_beginShutdown] (which
                          // needs a non-null FocusSession); a transient null
                          // (AsyncLoading during re-subscription, when the
                          // provider's retained `.value` still reads true)
                          // harmlessly falls through to the Plan-the-Day CTA.
                          if (showShutdownEntry && activeSession != null)
                            _PrimaryCallout(
                              kind: focusCalloutKindFor(reviewSurface, settlements),
                              onTap: () => _beginShutdown(
                                  context, ref, reviewSurface, activeSession),
                            )
                          else if (nudgeHead == null)
                            FilledButton(
                              onPressed: () => _replanDay(context, ref),
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFFEFF6FF),
                                foregroundColor: const Color(0xFF2563EB),
                                minimumSize: const Size.fromHeight(52),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                              ),
                              child: const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.wb_sunny_outlined, size: 18),
                                  SizedBox(width: 8),
                                  Text(
                                    'Plan the Day',
                                    style: TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                            ),
                          // Tasks carried over ('rollover' disposition) from
                          // the last closed session. "Last session", not
                          // "yesterday": sessions are calendar-independent and
                          // may span days (issue #460; CONTEXT.md § Engagement).
                          if (!planningDone && carriedOver.isNotEmpty) ...[
                            const SizedBox(height: 24),
                            const _SectionLabel(
                                'CARRIED OVER FROM LAST SESSION'),
                            const SizedBox(height: 8),
                            ...carriedOver
                                .map((t) => OutcomeRow(
                                  title: t.title,
                                  muted: true,
                                  timeEstimateMinutes: t.timeEstimate,
                                  leading: const Icon(Icons.update_outlined,
                                    size: 14, color: Color(0xFFD1D5DB)),
                                )),
                          ],
                          const SizedBox(height: 32),
                        ],
                      );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _replanDay(BuildContext context, WidgetRef ref) {
    // Entering the planning ceremony is a plain navigation. The reset of a
    // completed performance now happens on the sequenced Shutdown → Planning
    // path (see close_day_step.dart): Re-plan is only offered while a session
    // is open, so it lands on the blocked-start interstitial and passes
    // through Evening Shutdown first. A direct "Plan the Day" with no session
    // resumes the in-memory draft as today (issue #180 behaviour preserved).
    context.go('/focus-session-planning');
  }

  /// Either ends the session cleanly (every Outcome on the Review surface done) or routes the user into
  /// the evening-shutdown ritual where they assign dispositions to unfinished
  /// tasks. The session is only closed by [closeSession] / the ritual itself.
  ///
  /// The all-done test stays keyed on Completion alone, deliberately. A day
  /// where everything Settled to a non-done verdict must still go through
  /// Evening Shutdown: `closeSession` is not a Disposition commit point, so
  /// closing there would silently drop every implicit `rollover` — and it would
  /// skip the grouped summary on exactly the days that summary exists for. The
  /// rule the two branches encode: `closeSession` is for a day with nothing to
  /// dispose; `/shutdown` is for a day with anything.
  Future<void> _beginShutdown(
    BuildContext context,
    WidgetRef ref,
    List<Todo>? reviewSurface,
    FocusSession session,
  ) async {
    // Not loaded == something may be outstanding: go through the wizard.
    final allDone =
        reviewSurface != null && reviewSurface.every((t) => t.doneAt != null);
    if (allDone) {
      final db = ref.read(databaseProvider);
      await db.focusSessionDao.closeSession(sessionId: session.id);
      if (!context.mounted) return;
      context.go('/inbox');
    } else {
      context.go('/shutdown');
    }
  }
}

// ---------------------------------------------------------------------------
// Task row
// ---------------------------------------------------------------------------

Widget _focusOutcomeRow(
  BuildContext context, {
  required Todo todo,
  required String? currentTaskId,
  required SessionSettlement? settlement,
  required int sprintMinutes,
}) {
  final estimate = todo.timeEstimate;
  final isDone = todo.doneAt != null;
  final isSettled = settlement != null;
  // Completion alone owns the filled glyph; every Settlement strikes the title
  // and removes Start because the Outcome is handled for this session.
  return OutcomeRow(
    title: todo.title,
    struck: isDone || isSettled,
    onTap: () => context.push('/task/${todo.id}'),
    meta: estimate == null && todo.dueDate == null
        ? null
        : Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (estimate != null)
                Wrap(
                  spacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutcomeMetaLine(timeEstimateMinutes: estimate),
                    if (estimate > sprintMinutes) ...[
                      Text(
                        '· ${(estimate / sprintMinutes).ceil()} sprints',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF9CA3AF),
                        ),
                      ),
                    ],
                  ],
                ),
              if (todo.dueDate != null) OutcomeMetaLine(dueDate: todo.dueDate),
            ],
          ),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isDone)
          const Icon(Icons.check_circle, color: Color(0xFF2667B7), size: 20)
        else if (isSettled)
          const Icon(
            Icons.check_circle_outline,
            color: Color(0xFF9CA3AF),
            size: 20,
          )
        else
          _StartButton(todoId: todo.id, isResume: currentTaskId == todo.id),
        const SizedBox(width: 4),
        const Icon(Icons.chevron_right, color: Color(0xFF9CA3AF)),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Batching suggestion banner
// ---------------------------------------------------------------------------

class _BatchSuggestionBanner extends StatefulWidget {
  const _BatchSuggestionBanner({
    required this.candidates,
    required this.sprintMinutes,
  });
  final List<Todo> candidates;
  final int sprintMinutes;

  @override
  State<_BatchSuggestionBanner> createState() => _BatchSuggestionBannerState();
}

class _BatchSuggestionBannerState extends State<_BatchSuggestionBanner> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();

    final count = widget.candidates.length;
    final total = widget.candidates.fold<int>(
        0, (sum, t) => sum + (t.timeEstimate ?? 0));

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lightbulb_outline_rounded,
              size: 18, color: Color(0xFFD97706)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Batch $count micro-tasks into one sprint',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF92400E),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$count tasks · ${total}m total — fits in one ${widget.sprintMinutes}-min sprint.',
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFFB45309)),
                ),
              ],
            ),
          ),
          Semantics(
            button: true,
            label: 'Dismiss batching suggestion',
            child: GestureDetector(
              onTap: () => setState(() => _dismissed = true),
              child: const Icon(Icons.close_rounded,
                  size: 16, color: Color(0xFFD97706)),
            ),
          ),
        ],
      ),
    );
  }
}

class _StartButton extends ConsumerWidget {
  const _StartButton({required this.todoId, required this.isResume});

  final String todoId;
  final bool isResume;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FilledButton(
      onPressed: () async {
        // If the sprint timer is already running for this task (e.g. we are
        // mid-break or in overtime), just navigate back to the active screen
        // rather than resetting the session.
        final sprint = ref.read(sprintTimerProvider);
        if (sprint.isActive && sprint.activeTaskId == todoId) {
          if (context.mounted) context.push('/focus/active');
          return;
        }
        // If the in-memory focus state already tracks this task, just navigate.
        if (ref.read(focusModeProvider).activeTodoId == todoId) {
          if (context.mounted) context.push('/focus/active');
          return;
        }

        if (isResume) {
          // After a restart the in-memory focus state is cleared, but the DB
          // session still has current_task_id set. Re-attach to the open time
          // log rather than opening a new one.
          final db = ref.read(databaseProvider);
          final log = await db.timeLogDao.watchActiveLog().first;
          if (log != null && log.taskId == todoId) {
            ref
                .read(focusModeProvider.notifier)
                .resumeFrom(todoId, DateTime.parse(log.startedAt));
            if (context.mounted) context.push('/focus/active');
            return;
          }
        }

        await ref.read(focusModeProvider.notifier).startFocus(todoId);
        if (context.mounted) {
          context.push('/focus/active');
        }
      },
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFF2667B7),
        minimumSize: const Size(72, 36),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle:
            const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      child: Text(isResume ? 'Resume' : 'Start'),
    );
  }
}

// ---------------------------------------------------------------------------
// Section label + carried-over read-only row
// ---------------------------------------------------------------------------

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);
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

// ---------------------------------------------------------------------------
// Primary call-to-action footer
// ---------------------------------------------------------------------------

/// Which primary call-to-action the Now screen's footer offers.
///
/// [wrapUp] and [beginShutdown] both route to `/shutdown`; they differ only in
/// emphasis, because the label has to keep telling the truth about where the
/// tap goes. A filled "End Session" on a tap that opens a wizard would be copy
/// that lies.
@visibleForTesting
enum FocusCalloutKind { beginShutdown, wrapUp, endSession }

/// The footer's kind for [reviewSurface] (the session's Plan plus every Outcome
/// engaged off-Plan; null while not yet loaded) given [settlements].
///
/// * an unloaded surface → [FocusCalloutKind.beginShutdown]: unknown is never
///   treated as empty;
/// * every Outcome's Completion recorded → [FocusCalloutKind.endSession], the one
///   state `closeSession` may be reached from (see [FocusScreen._beginShutdown]);
/// * every task **Settled**, not all done → [FocusCalloutKind.wrapUp]: the user
///   is finished for the day, and the emphasis says so, but the tap still opens
///   Evening Shutdown so the day's Dispositions get committed;
/// * anything outstanding → [FocusCalloutKind.beginShutdown].
@visibleForTesting
FocusCalloutKind focusCalloutKindFor(
  List<Todo>? reviewSurface,
  Map<String, SessionSettlement> settlements,
) {
  if (reviewSurface == null) return FocusCalloutKind.beginShutdown;
  if (reviewSurface.every((t) => t.doneAt != null)) {
    return FocusCalloutKind.endSession;
  }
  if (reviewSurface.every((t) => settlements.containsKey(t.id))) {
    return FocusCalloutKind.wrapUp;
  }
  return FocusCalloutKind.beginShutdown;
}

class _PrimaryCallout extends StatelessWidget {
  const _PrimaryCallout({required this.kind, required this.onTap});

  final FocusCalloutKind kind;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (kind == FocusCalloutKind.endSession) {
      return FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF1E3A5F),
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
        ),
        child: const Text(
          'End Session',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        ),
      );
    }
    const label = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.nightlight_outlined, size: 18),
        SizedBox(width: 8),
        Text(
          'Begin Evening Shutdown',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        ),
      ],
    );
    // Everything on the Plan is Settled: the emphasis carries "you're finished
    // for the day" while the label keeps naming the destination.
    if (kind == FocusCalloutKind.wrapUp) {
      return FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF1E3A5F),
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(52),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: label,
      );
    }
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFF1E3A5F),
        backgroundColor: Colors.white,
        side: const BorderSide(color: Color(0xFF1E3A5F), width: 1.5),
        minimumSize: const Size.fromHeight(52),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: label,
    );
  }
}
