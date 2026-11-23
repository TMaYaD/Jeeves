/// Focus Mode on a Habit (issue #405): the Sprint ring and the controls to
/// run Sprints and breaks on a Habit with a time estimate.
///
/// The ring and its dots are the Outcome Focus screen's, unchanged
/// (`widgets/sprint_ring.dart`); what marks the Habit sits outside the ring:
/// the overline, the title and two chips. A Habit has no Action to complete,
/// so there is no Done: Stop closes the records and asks for a Check-in.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/clock_provider.dart';
import '../../providers/habit_focus_provider.dart';
import '../../providers/habits_provider.dart';
import '../../widgets/sprint_ring.dart';
import 'habit_copy.dart';
import 'habit_focus_check_in_sheet.dart';

class HabitFocusScreen extends ConsumerStatefulWidget {
  const HabitFocusScreen({super.key, required this.habitId});

  final String habitId;

  @override
  ConsumerState<HabitFocusScreen> createState() => _HabitFocusScreenState();
}

class _HabitFocusScreenState extends ConsumerState<HabitFocusScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl;
  bool _stopping = false;
  Future<void>? _beginFuture;
  bool _startRejected = false;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    // The Focus starts the moment the screen opens; a Focus already open on
    // this Habit (the app was closed mid-Focus) is adopted, not duplicated.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _beginFuture = _begin();
      unawaited(_beginFuture);
    });
  }

  Future<void> _begin() async {
    if (!mounted) return;
    try {
      await ref.read(habitFocusProvider.notifier).start(widget.habitId);
    } on StateError {
      // A Habit with no estimate, or one that is not active today, has no
      // Focus Mode: there is nothing to show.
      _leaveAfterRejectedStart();
    } on ArgumentError {
      // A Habit that is not there, or belongs to someone else.
      _leaveAfterRejectedStart();
    }
  }

  /// A rejected start opened no Focus: there is nothing to stop, so Stop and
  /// system back must not wait on it, and the screen goes.
  void _leaveAfterRejectedStart() {
    _startRejected = true;
    if (mounted && context.canPop()) context.pop();
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  /// Stop, and system back: closes the records, then leaves the screen.
  ///
  /// The session-end sheet asks "Add a check-in, sir?" every time, even when
  /// the Habit is already done today (several Check-ins a day are allowed).
  Future<void> _stop() async {
    if (_stopping) return;
    _stopping = true;
    // Everything the Stop needs from `ref` is taken before the first await:
    // the screen can be disposed while the start settles, and the Stop must
    // still close the Focus that start opened.
    final notifier = ref.read(habitFocusProvider.notifier);
    final clock = ref.read(clockProvider);
    // A Stop while the Focus is still starting waits for the start to settle,
    // so it closes the Focus instead of racing ahead of it.
    await _beginFuture;
    if (_startRejected) {
      _stopping = false;
      return;
    }
    final startedAt = mounted
        ? ref
            .read(habitFocusRecordsProvider(widget.habitId))
            .value
            ?.openLog
            ?.startedAt
        : null;
    try {
      await notifier.stop();
    } catch (_) {
      // The Focus is still open: release the latch so Stop can be tried again.
      _stopping = false;
      rethrow;
    }
    if (!mounted) return;
    // Read once the start has settled: a Habit that was still loading when
    // Stop was pressed must not skip the check-in sheet.
    final habit = await ref
        .read(habitByIdProvider(widget.habitId).future)
        .then((h) => h, onError: (_) => null);
    if (!mounted) return;
    if (habit != null) {
      final started =
          startedAt == null ? null : DateTime.tryParse(startedAt)?.toUtc();
      final minutesLogged = started == null
          ? 0
          : (clock().toUtc().difference(started).inSeconds / 60)
              .round()
              .clamp(0, 24 * 60);
      await showHabitFocusCheckInSheet(context, habit,
          minutesLogged: minutesLogged);
    }
    if (mounted && context.canPop()) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final timer = ref.watch(habitFocusProvider);
    final notifier = ref.read(habitFocusProvider.notifier);
    final habit = ref.watch(habitByIdProvider(widget.habitId)).value;
    // Held open so Stop can read when the Focus began, however long ago.
    ref.watch(habitFocusRecordsProvider(widget.habitId));
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isBreak = timer.isBreak;
    final ringColor =
        isBreak ? const Color(0xFF10B981) : const Color(0xFF2563EB);
    final estimate = habit?.timeEstimateMinutes;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_stop());
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.repeat, size: 16, color: colors.primary),
                        const SizedBox(width: 6),
                        Text(
                          habitFocusOverline,
                          key: const Key('habit_focus_overline'),
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: colors.primary,
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      habit?.title ?? '',
                      key: const Key('habit_focus_title'),
                      style: theme.textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        const Chip(
                          key: Key('habit_focus_plan_chip'),
                          label: Text(habitFocusNotInPlanChip),
                          visualDensity: VisualDensity.compact,
                        ),
                        if (estimate != null)
                          Chip(
                            key: const Key('habit_focus_estimate_chip'),
                            label: Text(habitFocusEstimateChip(estimate)),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final ringSize = math
                        .min(constraints.maxWidth - 72.0,
                            constraints.maxHeight * 0.72)
                        .clamp(160.0, 300.0);
                    return Center(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SprintRing(
                            timer: timer,
                            size: ringSize,
                            color: ringColor,
                            onPhaseSkip: timer.isProcessing || !timer.isActive
                                ? null
                                : () => unawaited(isBreak
                                    ? notifier.startSprint()
                                    : notifier.startBreak()),
                          ),
                          const SizedBox(width: 20),
                          SprintDotsColumn(timer: timer, pulseCtrl: _pulseCtrl),
                        ],
                      ),
                    );
                  },
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: colors.outlineVariant)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('habit_focus_stop'),
                        onPressed: () => unawaited(_stop()),
                        icon: const Icon(Icons.stop_rounded, size: 22),
                        label: const Text(habitFocusStopLabel),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: colors.error,
                          side: BorderSide(color: colors.error),
                          minimumSize: const Size.fromHeight(48),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        key: const Key('habit_focus_primary'),
                        onPressed: timer.isProcessing || !timer.isActive
                            ? null
                            : () => unawaited(isBreak
                                ? notifier.startSprint()
                                : notifier.startBreak()),
                        icon: Icon(isBreak
                            ? Icons.play_arrow_rounded
                            : Icons.coffee_outlined),
                        label: Text(isBreak
                            ? habitFocusNextSprintLabel
                            : habitFocusBreakLabel),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
