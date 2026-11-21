/// The streak numbers of a Habit's detail: the main streak and the best one,
/// then the three rate tiles. Everything comes from [HabitProgress]; nothing
/// is computed here.
library;

import 'package:flutter/material.dart';

import '../../../models/habit_progress.dart';
import '../habit_copy.dart';

class HabitStatsBlock extends StatelessWidget {
  const HabitStatsBlock({super.key, required this.progress});

  final HabitProgress progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kind = progress.mainStreakKind;
    final count = progress.periodCount;
    final target = progress.periodTarget;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                '${progress.currentStreak}',
                key: const Key('habit_stat_streak'),
                style: theme.textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      habitStreakLabel(kind),
                      key: const Key('habit_stat_streak_label'),
                      style: theme.textTheme.titleSmall,
                    ),
                    if (count != null && target != null)
                      Text(
                        habitPeriodProgressText(kind, count, target),
                        key: const Key('habit_stat_period'),
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${progress.bestStreak}',
                    key: const Key('habit_stat_best'),
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(habitBestStreakLabel, style: theme.textTheme.bodySmall),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The three rate tiles, under the strip.
class HabitRateTiles extends StatelessWidget {
  const HabitRateTiles({super.key, required this.progress});

  final HabitProgress progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labels = habitRateTileLabels(progress.mainStreakKind, [
      for (final rate in progress.rates) rate.windowLength,
    ]);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Row(
        children: [
          for (var i = 0; i < progress.rates.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    Text(
                      habitRateText(progress.rates[i].value),
                      key: Key('habit_stat_rate_$i'),
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      labels[i],
                      key: Key('habit_stat_rate_label_$i'),
                      style: theme.textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
