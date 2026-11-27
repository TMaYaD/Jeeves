/// The read-only habits card on Build Today's Plan.
///
/// Today's Habits in stack order, each with its number. Nothing here writes a
/// Check-in and nothing here counts towards capacity.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/habit_progress.dart' show HabitTodayState;
import '../../../providers/habit_progress_provider.dart';
import '../../../providers/place_gate_provider.dart';
import '../../habits/habit_copy.dart';

class PlanHabitsRow extends ConsumerWidget {
  const PlanHabitsRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final forToday = ref.watch(habitsForTodayProvider);
    final progressById = ref.watch(activeHabitProgressProvider);
    final chains = ref.watch(habitStackChainsProvider);
    final habits = [
      for (final chain in chains)
        for (final habit in chain)
          if (forToday.contains(habit.id) && progressById[habit.id] != null)
            habit,
    ];
    if (habits.isEmpty) return const SizedBox.shrink();

    final doneCount = habits
        .where((h) => progressById[h.id]!.todayState == HabitTodayState.done)
        .length;
    final allDone = doneCount == habits.length;
    final shown = habits.take(habitsTodayCardLimit).toList();
    final hiddenCount = habits.length - shown.length;
    final longestStreak = habits
        .map((h) => progressById[h.id]!.bestStreak)
        .reduce((a, b) => a > b ? a : b);

    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: DecoratedBox(
        key: const Key('plan_habits_card'),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFE5E7EB)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      habitsTodayHeader.toUpperCase(),
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                        color: Color(0xFF9CA3AF),
                      ),
                    ),
                  ),
                  Text(
                    habitsTodayDoneCount(doneCount, habits.length),
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (allDone)
                Text(
                  '${habitsTodayAllDoneLine(habits.length)} · '
                  '${habitsTodayLongestStreakLine(longestStreak)}',
                  style: theme.textTheme.bodyMedium,
                )
              else
                LayoutBuilder(
                  builder: (context, constraints) {
                    final columnWidth = constraints.maxWidth / 2;
                    return Wrap(
                      children: [
                        for (final habit in shown)
                          SizedBox(
                            width: columnWidth,
                            child: _HabitEntry(habitId: habit.id),
                          ),
                      ],
                    );
                  },
                ),
              if (hiddenCount > 0 && !allDone) ...[
                const SizedBox(height: 4),
                Text(habitsTodayMoreLine(hiddenCount),
                    style: theme.textTheme.labelSmall),
              ],
              const SizedBox(height: 8),
              Text(habitsTodayFooter, style: theme.textTheme.labelSmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _HabitEntry extends ConsumerWidget {
  const _HabitEntry({required this.habitId});

  final String habitId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final habit = ref
        .watch(habitStackChainsProvider)
        .expand((chain) => chain)
        .firstWhere((h) => h.id == habitId);
    final progress = ref.watch(activeHabitProgressProvider)[habitId]!;
    final commitment = ref.watch(habitTodayEntriesProvider(habitId))?.commitment;
    // A Habit is never hidden by its Place: the Place is said, not a gate.
    final placeName = ref.watch(habitPlaceNamesProvider)[habitId];
    final theme = Theme.of(context);
    final done = progress.todayState == HabitTodayState.done;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
      child: Row(
        children: [
          Icon(
            done ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(habit.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium),
                Text(
                  habitPlaceLine(
                    placeName: placeName,
                    line: habitPlanningNumber(progress, commitment),
                  ),
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
