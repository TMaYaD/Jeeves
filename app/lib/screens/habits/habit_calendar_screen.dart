/// The Check-in calendar of one Habit: a month of day marks, with arrows
/// that stop at the Habit's first judged month and at the current month.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../models/habit_commitment.dart' show habitDayKey;
import '../../models/habit_day_marks.dart';
import '../../models/habit_days.dart' show parseHabitDay;
import '../../models/habit_progress.dart';
import '../../providers/habit_progress_provider.dart';
import '../../widgets/habit_day_mark_grid.dart';
import 'habit_copy.dart';

const double _cellHeight = 64;
const double _markCenterY = 34;

DateTime _monthOf(DateTime day) => DateTime.utc(day.year, day.month);

class HabitCalendarScreen extends ConsumerStatefulWidget {
  const HabitCalendarScreen({super.key, required this.habitId});

  final String habitId;

  @override
  ConsumerState<HabitCalendarScreen> createState() =>
      _HabitCalendarScreenState();
}

class _HabitCalendarScreenState extends ConsumerState<HabitCalendarScreen> {
  /// The month shown, as its first day; null until the user moves, when the
  /// opening month applies.
  DateTime? _shownMonth;

  /// Whether the year view replaces the month view.
  bool _showYear = false;

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(habitHistoryProvider(widget.habitId));
    final todayKey = ref.watch(habitTodayProvider);
    final today = parseHabitDay(todayKey)!;
    final runs = history == null
        ? const <HabitCommitmentRun>[]
        : commitmentRuns(history, today);

    final currentMonth = _monthOf(today);
    final firstMonth = runs.isEmpty
        ? currentMonth
        : _monthOf(runs.first.firstDay);
    final month =
        (_shownMonth ?? _openingMonth(history, currentMonth, firstMonth));
    final shown = month.isBefore(firstMonth)
        ? firstMonth
        : month.isAfter(currentMonth)
        ? currentMonth
        : month;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              history == null
                  ? habitCalendarOverline
                  : '$habitCalendarOverline · ${history.habit.title}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const Text(habitCalendarTitle),
          ],
        ),
      ),
      body: history == null
          ? const Center(child: CircularProgressIndicator())
          : _showYear
          ? _YearView(
              history: history,
              today: today,
              year: shown.year,
              firstMonth: firstMonth,
              currentMonth: currentMonth,
              onYear: (year) => setState(
                () => _shownMonth = _clampMonth(
                  DateTime.utc(year, shown.month),
                  firstMonth,
                  currentMonth,
                ),
              ),
              onMonth: (m) => setState(() {
                _shownMonth = m;
                _showYear = false;
              }),
              onBackToMonth: () => setState(() => _showYear = false),
            )
          : _MonthView(
              history: history,
              today: today,
              month: shown,
              canGoBack: shown.isAfter(firstMonth),
              canGoForward: shown.isBefore(currentMonth),
              onMonth: (m) => setState(() => _shownMonth = m),
              onTitleTap: () => setState(() => _showYear = true),
            ),
    );
  }

  /// The current month, or for an archived Habit the month it was archived.
  DateTime _openingMonth(
    HabitHistory? history,
    DateTime currentMonth,
    DateTime firstMonth,
  ) {
    if (history == null) return currentMonth;
    for (final period in history.inactivePeriods) {
      if (period.kind == 'archived' && period.endsBefore == null) {
        final startsOn = parseHabitDay(period.startsOn);
        if (startsOn != null) {
          final month = _monthOf(startsOn);
          return month.isBefore(firstMonth) ? firstMonth : month;
        }
      }
    }
    return currentMonth;
  }
}

DateTime _clampMonth(DateTime month, DateTime first, DateTime last) =>
    month.isBefore(first)
    ? first
    : month.isAfter(last)
    ? last
    : month;

/// The twelve months of one year, each a small grid of day marks painted by
/// one `CustomPaint`; tapping a month opens it.
class _YearView extends ConsumerWidget {
  const _YearView({
    required this.history,
    required this.today,
    required this.year,
    required this.firstMonth,
    required this.currentMonth,
    required this.onYear,
    required this.onMonth,
    required this.onBackToMonth,
  });

  final HabitHistory history;
  final DateTime today;
  final int year;
  final DateTime firstMonth;
  final DateTime currentMonth;
  final ValueChanged<int> onYear;
  final ValueChanged<DateTime> onMonth;
  final VoidCallback onBackToMonth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: onBackToMonth,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Semantics(
                    button: true,
                    hint: habitCalendarShowMonth,
                    child: Text(
                      '$year',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: habitCalendarPreviousYear,
              icon: const Icon(Icons.chevron_left),
              onPressed: year > firstMonth.year ? () => onYear(year - 1) : null,
            ),
            IconButton(
              tooltip: habitCalendarNextYear,
              icon: const Icon(Icons.chevron_right),
              onPressed: year < currentMonth.year
                  ? () => onYear(year + 1)
                  : null,
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var m = 1; m <= 12; m++)
              _YearMonthTile(
                history: history,
                today: today,
                month: DateTime.utc(year, m),
                enabled:
                    !DateTime.utc(year, m).isBefore(firstMonth) &&
                    !DateTime.utc(year, m).isAfter(currentMonth),
                onTap: onMonth,
              ),
          ],
        ),
      ],
    );
  }
}

const double _yearCellHeight = 9;

class _YearMonthTile extends ConsumerWidget {
  const _YearMonthTile({
    required this.history,
    required this.today,
    required this.month,
    required this.enabled,
    required this.onTap,
  });

  final HabitHistory history;
  final DateTime today;
  final DateTime month;
  final bool enabled;
  final ValueChanged<DateTime> onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lastDay = DateTime.utc(month.year, month.month + 1, 0);
    final marks =
        ref.watch(
          habitDayMarksProvider((
            habitId: history.habit.id,
            fromDay: habitDayKey(month),
            toDay: habitDayKey(lastDay),
          )),
        ) ??
        const <HabitDayMark>[];
    final cells = <HabitDayMark?>[
      for (var i = 0; i < month.weekday - 1; i++) null,
      ...marks,
    ];
    final name = DateFormat('MMMM').format(month);
    final width = (MediaQuery.sizeOf(context).width - 32 - 16) / 3;
    return Semantics(
      button: true,
      enabled: enabled,
      label: '$name ${month.year}',
      child: ExcludeSemantics(
        child: InkWell(
          onTap: enabled ? () => onTap(month) : null,
          child: Opacity(
            opacity: enabled ? 1 : 0.4,
            child: SizedBox(
              width: width,
              height: 6 * _yearCellHeight + 32,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: Theme.of(context).textTheme.labelMedium),
                    const SizedBox(height: 4),
                    HabitDayMarkGrid(
                      cells: cells,
                      cellHeight: _yearCellHeight,
                      markRadius: 3,
                      markCenterY: _yearCellHeight / 2,
                      todayDay: today,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MonthView extends ConsumerWidget {
  const _MonthView({
    required this.history,
    required this.today,
    required this.month,
    required this.canGoBack,
    required this.canGoForward,
    required this.onMonth,
    required this.onTitleTap,
  });

  final HabitHistory history;
  final DateTime today;
  final DateTime month;
  final bool canGoBack;
  final bool canGoForward;
  final ValueChanged<DateTime> onMonth;
  final VoidCallback onTitleTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lastDay = DateTime.utc(month.year, month.month + 1, 0);
    final marks =
        ref.watch(
          habitDayMarksProvider((
            habitId: history.habit.id,
            fromDay: habitDayKey(month),
            toDay: habitDayKey(lastDay),
          )),
        ) ??
        const <HabitDayMark>[];
    final leadingBlanks = month.weekday - 1;
    final cells = <HabitDayMark?>[
      for (var i = 0; i < leadingBlanks; i++) null,
      ...marks,
    ];
    final rows = (cells.length / 7).ceil();
    final changes = [
      for (final m in marks)
        if (m.commitmentStartsHere) m,
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: onTitleTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Semantics(
                    button: true,
                    hint: habitCalendarShowYear,
                    child: Text(
                      DateFormat('MMMM yyyy').format(month),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: habitCalendarPreviousMonth,
              icon: const Icon(Icons.chevron_left),
              onPressed: canGoBack
                  ? () => onMonth(DateTime.utc(month.year, month.month - 1))
                  : null,
            ),
            IconButton(
              tooltip: habitCalendarNextMonth,
              icon: const Icon(Icons.chevron_right),
              onPressed: canGoForward
                  ? () => onMonth(DateTime.utc(month.year, month.month + 1))
                  : null,
            ),
          ],
        ),
        Row(
          children: [
            for (var d = 1; d <= 7; d++)
              Expanded(
                child: ExcludeSemantics(
                  child: Center(
                    child: Text(
                      DateFormat('E').format(DateTime.utc(2026, 11, 8 + d)),
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Stack(
          children: [
            HabitDayMarkGrid(
              cells: cells,
              cellHeight: _cellHeight,
              todayDay: today,
            ),
            SizedBox(
              height: rows * _cellHeight,
              child: Column(
                children: [
                  for (var r = 0; r < rows; r++)
                    SizedBox(
                      height: _cellHeight,
                      child: Row(
                        children: [
                          for (var c = 0; c < 7; c++)
                            Expanded(
                              child: _cellAt(r * 7 + c, cells, today, history),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (final change in changes)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.flag_outlined, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${DateFormat('E d MMM').format(change.day)} · '
                    '$habitCalendarRepeatChangedNote',
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        const _Legend(),
      ],
    );
  }

  Widget _cellAt(
    int index,
    List<HabitDayMark?> cells,
    DateTime today,
    HabitHistory history,
  ) {
    if (index >= cells.length || cells[index] == null) {
      return const SizedBox.shrink();
    }
    return _DayCell(mark: cells[index]!, today: today, history: history);
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.mark,
    required this.today,
    required this.history,
  });

  final HabitDayMark mark;
  final DateTime today;
  final HabitHistory history;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final faint = theme.colorScheme.outline;
    final state = mark.state;
    final dimmed =
        state == HabitDayState.notDue ||
        state == HabitDayState.future ||
        state == HabitDayState.paused ||
        state == HabitDayState.archived;
    final measurable = mark.totalAmount != null && mark.targetAmount != null;
    final judged =
        state != HabitDayState.beforeHabit && state != HabitDayState.future;
    final valueText = measurable && judged && (mark.totalAmount ?? 0) > 0
        ? habitDayAmountText(mark.totalAmount!, mark.targetAmount!)
        : null;

    return Semantics(
      container: true,
      label: _label(),
      child: ExcludeSemantics(
        child: Stack(
          children: [
            Positioned(
              top: 6,
              left: 0,
              right: 0,
              child: Center(
                child: state == HabitDayState.beforeHabit
                    ? Text('·', style: TextStyle(color: faint))
                    : Text(
                        '${mark.day.day}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: dimmed ? faint : null,
                        ),
                      ),
              ),
            ),
            if (mark.checkInCount > 1)
              Positioned(
                top: 4,
                left: 4,
                child: Text(
                  habitCheckInCountMark(mark.checkInCount),
                  style: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            if (mark.commitmentStartsHere)
              Positioned(
                top: 3,
                right: 3,
                child: Icon(Icons.flag_outlined, size: 11, color: faint),
              ),
            if (valueText != null)
              Positioned(
                top: _markCenterY + 14,
                left: 0,
                right: 0,
                child: Center(
                  child: Text(valueText, style: const TextStyle(fontSize: 9)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _label() {
    final parts = <String>[
      DateFormat('d MMMM').format(mark.day),
      habitDayStateWords(mark.state.name),
    ];
    if (mark.totalAmount != null &&
        mark.targetAmount != null &&
        mark.state != HabitDayState.beforeHabit &&
        mark.state != HabitDayState.future) {
      final unit = mark.unitLabel;
      parts.add(
        '${habitDayAmountText(mark.totalAmount!, mark.targetAmount!)}'
        '${unit == null ? '' : ' $unit'}',
      );
    }
    if (mark.checkInCount > 0) {
      parts.add(habitCheckInCountWords(mark.checkInCount));
    }
    if (mark.state == HabitDayState.done && !mark.counted) {
      final kind = inactiveKindOn(history.inactivePeriods, mark.day);
      parts.add(switch (kind) {
        HabitInactiveKind.paused => habitDayNotCountedPaused,
        HabitInactiveKind.archived => habitDayNotCountedArchived,
        null => habitDayNotCountedRestDay,
      });
    }
    if (mark.commitmentStartsHere) parts.add(habitDayRepeatChangedWords);
    if (mark.day == today) parts.add(habitDayToday);
    return parts.join(', ');
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final faint = Theme.of(context).colorScheme.outline;
    return Wrap(
      spacing: 16,
      runSpacing: 8,
      children: [
        for (final item in HabitCalendarLegendItem.values)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: switch (item) {
                  HabitCalendarLegendItem.checkIn => const HabitDayMarkSwatch(
                    shape: HabitDayMarkShape.filled,
                    size: 20,
                  ),
                  HabitCalendarLegendItem.noCheckIn => const HabitDayMarkSwatch(
                    shape: HabitDayMarkShape.ring,
                    size: 20,
                  ),
                  HabitCalendarLegendItem.notDue => const HabitDayMarkSwatch(
                    shape: HabitDayMarkShape.dot,
                    size: 20,
                  ),
                  HabitCalendarLegendItem.paused => const HabitDayMarkSwatch(
                    shape: HabitDayMarkShape.pauseRing,
                    size: 20,
                  ),
                  HabitCalendarLegendItem.beforeHabit => Center(
                    child: Text('·', style: TextStyle(color: faint)),
                  ),
                  HabitCalendarLegendItem.repeatChanged => Icon(
                    Icons.flag_outlined,
                    size: 14,
                    color: faint,
                  ),
                },
              ),
              const SizedBox(width: 6),
              Text(item.label, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
      ],
    );
  }
}
