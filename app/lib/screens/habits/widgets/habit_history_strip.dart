/// The last five months of a Habit as untitled grids of day marks, newest on
/// the right, fading towards the left. One tap target; it opens the Check-in
/// calendar.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/habit_commitment.dart' show habitDayKey;
import '../../../models/habit_day_marks.dart';
import '../../../models/habit_days.dart' show parseHabitDay;
import '../../../providers/habit_progress_provider.dart';
import '../../../widgets/habit_day_mark_grid.dart';
import '../habit_copy.dart';
import '../habit_routes.dart';

const int _monthCount = 5;
const double _stripCellHeight = 11;
const double _stripMarkRadius = 3.5;

class HabitHistoryStrip extends ConsumerWidget {
  const HabitHistoryStrip({super.key, required this.habitId});

  final String habitId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = parseHabitDay(ref.watch(habitTodayProvider))!;
    final firstMonth = DateTime.utc(
      today.year,
      today.month - (_monthCount - 1),
    );
    final lastDay = DateTime.utc(today.year, today.month + 1, 0);
    final marks = ref.watch(
      habitDayMarksProvider((
        habitId: habitId,
        fromDay: habitDayKey(firstMonth),
        toDay: habitDayKey(lastDay),
      )),
    );
    if (marks == null) return const SizedBox.shrink();

    final months = <List<HabitDayMark?>>[];
    var checkInDays = 0;
    var dueDays = 0;
    for (var i = 0; i < _monthCount; i++) {
      final month = DateTime.utc(firstMonth.year, firstMonth.month + i);
      final inMonth = [
        for (final mark in marks)
          if (mark.day.year == month.year && mark.day.month == month.month)
            mark,
      ];
      months.add([
        for (var b = 0; b < month.weekday - 1; b++) null,
        ...inMonth,
      ]);
      for (final mark in inMonth) {
        switch (mark.state) {
          case HabitDayState.done || HabitDayState.partial:
            checkInDays++;
            if (mark.counted) dueDays++;
          case HabitDayState.missed || HabitDayState.openToday:
            dueDays++;
          default:
            break;
        }
      }
    }

    return Semantics(
      button: true,
      label: habitHistoryStripLabel(checkInDays, dueDays),
      excludeSemantics: true,
      onTap: () => openHabitCalendar(context, habitId),
      child: InkWell(
        key: const Key('habit_history_strip'),
        onTap: () => openHabitCalendar(context, habitId),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (rect) => const LinearGradient(
              colors: [Color(0x00FFFFFF), Color(0xFFFFFFFF)],
              stops: [0, 0.48],
            ).createShader(rect),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < months.length; i++) ...[
                  if (i > 0) const SizedBox(width: 12),
                  Expanded(
                    child: HabitDayMarkGrid(
                      cells: months[i],
                      cellHeight: _stripCellHeight,
                      markRadius: _stripMarkRadius,
                      markCenterY: _stripCellHeight / 2,
                      todayDay: today,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
