library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../models/day_timeline.dart';
import '../../../providers/clock_provider.dart';
import '../../../providers/day_timeline_provider.dart';
import '../../../providers/focus_session_planning_provider.dart';
import '../../../providers/focus_session_planning_settings_provider.dart';
import '../../../providers/focus_settings_provider.dart';
import '../../../widgets/day_timeline/day_timeline.dart';
import '../../../widgets/outcome_row.dart';

class ScheduledReviewStep extends ConsumerStatefulWidget {
  const ScheduledReviewStep({super.key});

  @override
  ConsumerState<ScheduledReviewStep> createState() =>
      _ScheduledReviewStepState();
}

class _ScheduledReviewStepState extends ConsumerState<ScheduledReviewStep> {
  /// Where the day starts, fixed when the screen opens so the layout does not
  /// shift under the user as the clock moves.
  late final DateTime _flowOrigin =
      roundUpToFiveMinutes(ref.read(clockProvider)());

  @override
  Widget build(BuildContext context) {
    final asyncSelected = ref.watch(focusSessionPlanningSelectedTasksProvider);

    return asyncSelected.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Error: $err')),
      data: (tasks) {
        final withDue = tasks.where((t) => t.dueDate != null).toList()
          ..sort((a, b) => a.dueDate!.compareTo(b.dueDate!));
        final noDue = tasks.where((t) => t.dueDate == null).toList();
        final sortedTasks = [...withDue, ...noDue];

        return ListView(
          physics: const ClampingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
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
            if (sortedTasks.isNotEmpty) _timeline(sortedTasks),
            const SizedBox(height: 36),
            const Divider(height: 1, color: Color(0xFFF3F4F6)),
            const SizedBox(height: 36),
            const Text(
              "Today's Tasks",
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1A1A2E),
              ),
            ),
            const SizedBox(height: 16),
            if (sortedTasks.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'No tasks selected — go back and select some!',
                  style: TextStyle(fontSize: 14, color: Colors.grey[400]),
                  textAlign: TextAlign.center,
                ),
              )
            else
              ...sortedTasks.map((t) => OutcomeRow(
                title: t.title,
                timeEstimateMinutes: t.timeEstimate,
                dueDate: t.dueDate,
                framed: true,
                leading: const Icon(Icons.check_circle_outline,
                    size: 20, color: Color(0xFF16A34A)),
              )),
            const SizedBox(height: 48),
            FilledButton(
              onPressed: () => _startDay(context, ref),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text(
                'Start Day',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 32),
          ],
        );
      },
    );
  }

  Widget _timeline(List<Todo> tasks) {
    final planning = ref.watch(focusSessionPlanningProvider);
    final focusSettings = ref.watch(focusSettingsProvider);
    final defaultEstimate =
        ref.watch(focusSessionPlanningSettingsProvider).defaultTimeEstimate;
    final timeContexts =
        ref.watch(currentTimeContextsProvider).asData?.value ?? const {};
    final entries = dayTimelineEntriesFor(
      tasks: tasks,
      defaultEstimateMinutes: defaultEstimate,
      now: _flowOrigin,
      timeContexts: timeContexts,
      pinnedStarts: planning.pinnedStartByTaskId,
    );
    return DayTimeline(
      scope: 'planning',
      entries: entries,
      flowOrigin: _flowOrigin,
      availableMinutes: planning.availableMinutes,
      chunkUnitMinutes:
          focusSettings.sprintDurationMinutes + focusSettings.breakDurationMinutes,
      onSetPinnedStart: (outcomeId, startAt) async => ref
          .read(focusSessionPlanningProvider.notifier)
          .setPinnedStart(outcomeId, startAt),
    );
  }

  Future<void> _startDay(BuildContext context, WidgetRef ref) async {
    // Taken before the await: starting the day resets the planning step and
    // opens a session, either of which unmounts this step while startDay() is
    // still awaiting the store (#901). The router outlives it.
    final router = GoRouter.of(context);
    final notifier = ref.read(focusSessionPlanningProvider.notifier);
    try {
      await notifier.startDay();
    } catch (e) {
      debugPrint('Failed to start day: $e');
      return;
    }
    router.go('/focus');
  }
}
