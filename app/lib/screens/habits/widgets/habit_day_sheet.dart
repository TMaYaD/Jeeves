/// The sheet that corrects one day of a Habit: it lists the day's Check-ins
/// and adds, changes or removes them. Removing happens at once, with no
/// confirmation and no undo.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../models/habit_day_marks.dart';
import '../../../providers/habit_check_ins_provider.dart';
import '../../../providers/habit_progress_provider.dart';
import '../habit_copy.dart';

/// Whether tapping [state]'s day opens a sheet: not before the Habit, not in
/// the future.
bool habitDayOpensSheet(HabitDayState state) =>
    state != HabitDayState.beforeHabit && state != HabitDayState.future;

Future<void> showHabitDaySheet(
  BuildContext context, {
  required String habitId,
  required DateTime day,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (_) => HabitDaySheet(habitId: habitId, day: day),
);

class HabitDaySheet extends ConsumerStatefulWidget {
  const HabitDaySheet({super.key, required this.habitId, required this.day});

  final String habitId;
  final DateTime day;

  @override
  ConsumerState<HabitDaySheet> createState() => _HabitDaySheetState();
}

class _HabitDaySheetState extends ConsumerState<HabitDaySheet> {
  double? _newAmount;

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(habitHistoryProvider(widget.habitId));
    final marks = ref.watch(
      habitDayMarksProvider((
        habitId: widget.habitId,
        fromDay: _key(widget.day),
        toDay: _key(widget.day),
      )),
    );
    if (history == null || marks == null || marks.isEmpty) {
      return const SizedBox(height: 120);
    }
    final mark = marks.first;
    final measurable = mark.targetAmount != null;
    final actions = ref.read(habitCheckInsProvider.notifier);
    final theme = Theme.of(context);
    final unit = mark.unitLabel;
    final inactive = inactiveKindOn(history.inactivePeriods, widget.day);
    final title = history.habit.title;
    final entries = [...mark.checkIns]
      ..sort((a, b) => a.checkedInAt.compareTo(b.checkedInAt));
    final amount = _newAmount ?? 1;

    final String line;
    if (measurable) {
      line = habitDaySheetMeasurableLine(
        title,
        mark.totalAmount ?? 0,
        mark.targetAmount!,
        unit,
        entries.length,
      );
    } else if (entries.isEmpty) {
      line = habitDaySheetEmptyLine(title);
    } else {
      line = habitDaySheetBinaryLine(title, entries.length);
    }

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                habitDaySheetTitle(widget.day),
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(line, style: theme.textTheme.bodyMedium),
              if (inactive != null ||
                  (!mark.counted && (entries.isNotEmpty || measurable))) ...[
                const SizedBox(height: 8),
                Text(habitDaySheetPausedLine, style: theme.textTheme.bodySmall),
              ] else if (entries.isEmpty && !measurable) ...[
                const SizedBox(height: 8),
                Text(
                  habitDaySheetCountsNote(widget.day),
                  style: theme.textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 12),
              for (final entry in entries)
                Row(
                  key: Key('habit_day_entry_${entry.id}'),
                  children: [
                    Text(
                      DateFormat('HH:mm').format(
                        DateTime.parse(entry.checkedInAt).toLocal(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: measurable
                          ? Text(
                              '${habitAmountText(entry.measuredAmount ?? 0)}'
                              '${unit == null ? '' : ' $unit'}',
                            )
                          : const SizedBox.shrink(),
                    ),
                    if (measurable)
                      IconButton(
                        tooltip: habitDaySheetChangeTooltip,
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _change(entry.id, entry.measuredAmount),
                      ),
                    IconButton(
                      tooltip: habitDaySheetRemoveTooltip,
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => actions.remove(entry.id),
                    ),
                  ],
                ),
              if (measurable)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: habitDaySheetAmountDecrease,
                      icon: const Icon(Icons.remove),
                      onPressed: amount > 1
                          ? () => setState(() => _newAmount = amount - 1)
                          : null,
                    ),
                    TextButton(
                      key: const Key('habit_day_new_amount_button'),
                      onPressed: () => _enterAmount(amount),
                      child: Text(
                        '${habitAmountText(amount)}'
                        '${unit == null ? '' : ' $unit'}',
                        key: const Key('habit_day_new_amount'),
                      ),
                    ),
                    IconButton(
                      tooltip: habitDaySheetAmountIncrease,
                      icon: const Icon(Icons.add),
                      onPressed: () => setState(() => _newAmount = amount + 1),
                    ),
                  ],
                ),
              const SizedBox(height: 8),
              FilledButton.icon(
                  key: const Key('habit_day_add'),
                  icon: const Icon(Icons.check),
                  label: const Text(habitDaySheetAdd),
                  onPressed: () => actions.checkIn(
                    widget.habitId,
                    amount: measurable ? amount : null,
                    countsForDay: _key(widget.day),
                  ),
                ),
              TextButton(
                key: const Key('habit_day_close'),
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  measurable ? habitDaySheetDone : habitDaySheetClose,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _enterAmount(double current) async {
    final value = await showDialog<double>(
      context: context,
      builder: (_) => _ChangeAmountDialog(initial: current),
    );
    if (value != null) setState(() => _newAmount = value);
  }

  Future<void> _change(String checkInId, double? current) async {
    final value = await showDialog<double>(
      context: context,
      builder: (_) => _ChangeAmountDialog(initial: current ?? 0),
    );
    if (value != null) {
      await ref.read(habitCheckInsProvider.notifier).change(checkInId, value);
    }
  }

  static String _key(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// Asks for the new amount of one Check-in; pops the amount above 0.
class _ChangeAmountDialog extends StatefulWidget {
  const _ChangeAmountDialog({required this.initial});

  final double initial;

  @override
  State<_ChangeAmountDialog> createState() => _ChangeAmountDialogState();
}

class _ChangeAmountDialogState extends State<_ChangeAmountDialog> {
  late final TextEditingController _controller = TextEditingController(
    // Plain digits: the grouped display text would not parse back.
    text: widget.initial == widget.initial.roundToDouble()
        ? widget.initial.round().toString()
        : widget.initial.toString(),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    content: TextField(
      key: const Key('habit_day_change_field'),
      controller: _controller,
      autofocus: true,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: const InputDecoration(labelText: habitDaySheetAmountLabel),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('habit_day_change_save'),
        onPressed: () {
          final parsed = double.tryParse(_controller.text.trim());
          if (parsed != null && parsed.isFinite && parsed > 0) {
            Navigator.of(context).pop(parsed);
          }
        },
        child: const Text(habitDaySheetDone),
      ),
    ],
  );
}
