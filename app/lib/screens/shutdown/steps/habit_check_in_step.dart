/// The Evening Shutdown habit step: the Habits for the day being closed that
/// are still open, each with a quick Check-in.
///
/// A binary Habit is a toggle; a measurable one has an inline − / + stepper
/// (minimum 1) and an Add button, and every entry adds to the day. Nothing is
/// written for a Habit the user leaves alone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/habit_commitment.dart'
    show habitDateFromDayKey, habitDayKey;
import '../../../providers/clock_provider.dart';
import '../../../providers/habit_progress_provider.dart';
import '../../../providers/shutdown_habits_provider.dart';
import '../../../widgets/habit_check_in_mark.dart';
import '../../../models/habit_progress.dart' show HabitProgress;
import '../../habits/habit_copy.dart';

class HabitCheckInStep extends ConsumerWidget {
  const HabitCheckInStep({
    super.key,
    required this.closingDay,
    required this.habits,
  });

  /// The day being closed (`yyyy-MM-dd`).
  final String closingDay;

  /// The open Habits, latched on first entry so a row stays after its Check-in.
  final List<ShutdownOpenHabit> habits;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final closing = habitDateFromDayKey(closingDay);
    final todayKey = habitDayKey(ref.watch(clockProvider)());
    final made = ref.watch(shutdownHabitCheckInsProvider);
    final liveProgress = ref.watch(habitProgressOnDayProvider(closingDay));
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        if (closing != null && closingDay != todayKey)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              habitShutdownClosingDayLine(closing),
              key: const Key('shutdown_habit_closing_day'),
              style: theme.textTheme.titleSmall,
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(
            habitShutdownLine(closingDay),
            key: const Key('shutdown_habit_line'),
            style: theme.textTheme.bodyLarge,
          ),
        ),
        for (final open in habits)
          open.progress.targetAmount == null
              ? _BinaryRow(
                  key: Key('shutdown_habit_row_${open.habit.id}'),
                  open: open,
                  closingDay: closingDay,
                  checkedInHere: (made[open.habit.id] ?? const []).isNotEmpty,
                )
              : _MeasurableRow(
                  key: Key('shutdown_habit_row_${open.habit.id}'),
                  open: open,
                  closingDay: closingDay,
                  progress: liveProgress[open.habit.id] ?? open.progress,
                ),
      ],
    );
  }
}

class _BinaryRow extends ConsumerWidget {
  const _BinaryRow({
    super.key,
    required this.open,
    required this.closingDay,
    required this.checkedInHere,
  });

  final ShutdownOpenHabit open;
  final String closingDay;
  final bool checkedInHere;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: HabitCheckInMark(
        key: Key('shutdown_habit_toggle_${open.habit.id}'),
        state: checkedInHere
            ? HabitCheckInMarkState.done
            : HabitCheckInMarkState.open,
        onTap: () => ref
            .read(shutdownHabitCheckInsProvider.notifier)
            .toggleBinary(open.habit.id, closingDay),
      ),
      title: Text(open.habit.title),
    );
  }
}

class _MeasurableRow extends ConsumerStatefulWidget {
  const _MeasurableRow({
    super.key,
    required this.open,
    required this.closingDay,
    required this.progress,
  });

  final ShutdownOpenHabit open;
  final String closingDay;
  final HabitProgress progress;

  @override
  ConsumerState<_MeasurableRow> createState() => _MeasurableRowState();
}

class _MeasurableRowState extends ConsumerState<_MeasurableRow> {
  int _stepperAmount = 1;

  @override
  Widget build(BuildContext context) {
    final habitId = widget.open.habit.id;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.open.habit.title, style: theme.textTheme.titleMedium),
          Text(
            habitAmountLine(widget.progress),
            key: Key('shutdown_habit_amount_$habitId'),
          ),
          Row(
            children: [
              IconButton(
                tooltip: habitSheetLessLabel,
                onPressed: _stepperAmount > 1
                    ? () => setState(() => _stepperAmount--)
                    : null,
                icon: const Icon(Icons.remove),
              ),
              Text('$_stepperAmount',
                  key: Key('shutdown_habit_stepper_$habitId')),
              IconButton(
                tooltip: habitSheetMoreLabel,
                onPressed: () => setState(() => _stepperAmount++),
                icon: const Icon(Icons.add),
              ),
              const Spacer(),
              FilledButton(
                key: Key('shutdown_habit_add_$habitId'),
                onPressed: () async {
                  final amount = _stepperAmount;
                  setState(() => _stepperAmount = 1);
                  await ref
                      .read(shutdownHabitCheckInsProvider.notifier)
                      .addAmount(habitId, widget.closingDay, amount.toDouble());
                },
                child: const Text(habitShutdownAddLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
