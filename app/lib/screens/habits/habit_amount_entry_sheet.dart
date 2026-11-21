/// The bottom sheet where a measurable Habit's Check-ins are entered.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../database/gtd_database.dart' show Habit, HabitCheckIn;
import '../../models/habit_commitment.dart' show habitDateFromDayKey;
import '../../providers/habit_check_ins_provider.dart';
import '../../providers/habit_progress_provider.dart';
import '../../providers/habit_stack_offer_provider.dart';
import 'habit_copy.dart';
import 'habit_row.dart' show HabitOfferButtons;

/// Opens the entry sheet of [habit].
Future<void> showHabitAmountEntrySheet(BuildContext context, Habit habit) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => HabitAmountEntrySheet(habit: habit),
  );
}

class HabitAmountEntrySheet extends ConsumerStatefulWidget {
  const HabitAmountEntrySheet({super.key, required this.habit});

  final Habit habit;

  @override
  ConsumerState<HabitAmountEntrySheet> createState() =>
      _HabitAmountEntrySheetState();
}

class _HabitAmountEntrySheetState extends ConsumerState<HabitAmountEntrySheet> {
  int _stepperAmount = 1;
  String? _editingCheckInId;

  Future<void> _add(int amount) async {
    await ref
        .read(habitCheckInsProvider.notifier)
        .checkIn(widget.habit.id, amount: amount.toDouble());
    ref.read(habitStackOfferProvider.notifier).checkedIn(widget.habit.id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final progress = ref.watch(habitProgressProvider(widget.habit.id));
    final entries = ref.watch(habitTodayEntriesProvider(widget.habit.id));
    if (progress == null || entries == null) return const SizedBox.shrink();
    final today = habitDateFromDayKey(ref.watch(habitTodayProvider));
    final total = progress.todayTotalAmount ?? 0;
    final target = progress.targetAmount ?? 0;
    final status = habitSheetStatusLine(progress);
    final unit = progress.unitLabel;
    final offered = ref.watch(offeredHabitProvider);
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          24,
          0,
          24,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          key: const Key('habit_entry_sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.repeat, size: 16, color: scheme.primary),
                const SizedBox(width: 4),
                Text(
                  habitSheetOverline,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.primary,
                  ),
                ),
              ],
            ),
            Text(
              widget.habit.title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            if (today != null)
              Text(habitSheetDayLine(today), style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  habitAmountText(total),
                  key: const Key('habit_sheet_total'),
                  style: theme.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 8),
                Text(habitSheetOfTargetLine(progress)),
                const Spacer(),
                if (status != null)
                  Flexible(
                    child: Text(
                      status,
                      key: const Key('habit_sheet_status'),
                      textAlign: TextAlign.end,
                      style: TextStyle(color: scheme.primary),
                    ),
                  )
                else ...[
                  Icon(Icons.check, size: 18, color: scheme.primary),
                  Text(
                    habitSheetTargetReachedLine,
                    key: const Key('habit_sheet_status'),
                    style: TextStyle(color: scheme.primary),
                  ),
                ],
              ],
            ),
            if (habitShowsPips(target)) ...[
              const SizedBox(height: 8),
              _SheetPips(target: target.round(), total: total),
            ],
            const SizedBox(height: 8),
            for (final checkIn in entries.checkIns)
              _EntryRow(
                key: Key('habit_entry_${checkIn.id}'),
                checkIn: checkIn,
                unit: unit,
                editing: _editingCheckInId == checkIn.id,
                onToggleEdit: () => setState(
                  () => _editingCheckInId =
                      _editingCheckInId == checkIn.id ? null : checkIn.id,
                ),
              ),
            if (offered != null && ref.watch(habitStackOfferProvider) == widget.habit.id)
              _SheetOfferCard(offered: offered),
            const SizedBox(height: 8),
            Row(
              children: [
                IconButton(
                  tooltip: habitSheetLessLabel,
                  onPressed: _stepperAmount > 1
                      ? () => setState(() => _stepperAmount--)
                      : null,
                  icon: const Icon(Icons.remove),
                ),
                Text(
                  '$_stepperAmount',
                  key: const Key('habit_sheet_stepper'),
                  style: theme.textTheme.titleMedium,
                ),
                IconButton(
                  tooltip: habitSheetMoreLabel,
                  onPressed: () => setState(() => _stepperAmount++),
                  icon: const Icon(Icons.add),
                ),
                for (final quick in habitSheetQuickAmounts)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: ActionChip(
                      key: Key('habit_sheet_chip_$quick'),
                      label: Text('+$quick'),
                      onPressed: () => _add(quick),
                    ),
                  ),
                Expanded(
                  child: FilledButton(
                    key: const Key('habit_sheet_add'),
                    onPressed: () async {
                      final amount = _stepperAmount;
                      setState(() => _stepperAmount = 1);
                      await _add(amount);
                    },
                    child: const Text(habitSheetAddLabel),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                key: const Key('habit_sheet_done'),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text(habitSheetDoneLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetPips extends StatelessWidget {
  const _SheetPips({required this.target, required this.total});

  final int target;
  final double total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final over = total - target;
    return Wrap(
      key: const Key('habit_sheet_pips'),
      spacing: 3,
      runSpacing: 3,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < target; i++)
          Container(
            width: 30,
            height: 12,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              color: i < total ? scheme.primary : scheme.surfaceContainerHighest,
            ),
          ),
        if (over > 0)
          Text(
            '+${habitAmountText(over)}',
            style: TextStyle(color: scheme.primary),
          ),
      ],
    );
  }
}

class _EntryRow extends ConsumerWidget {
  const _EntryRow({
    super.key,
    required this.checkIn,
    required this.unit,
    required this.editing,
    required this.onToggleEdit,
  });

  final HabitCheckIn checkIn;
  final String? unit;
  final bool editing;
  final VoidCallback onToggleEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ref.read(habitCheckInsProvider.notifier);
    final amount = checkIn.measuredAmount ?? 0;
    return Row(
      children: [
        Text(habitCheckInClock(checkIn)),
        const SizedBox(width: 12),
        Expanded(
          child: editing
              ? Row(
                  children: [
                    IconButton(
                      tooltip: habitSheetLessLabel,
                      onPressed: amount > 1
                          ? () => actions.change(checkIn.id, amount - 1)
                          : null,
                      icon: const Icon(Icons.remove),
                    ),
                    Text(habitAmountText(amount)),
                    IconButton(
                      tooltip: habitSheetMoreLabel,
                      onPressed: () => actions.change(checkIn.id, amount + 1),
                      icon: const Icon(Icons.add),
                    ),
                  ],
                )
              : Text(habitEntryAmountText(amount, unit)),
        ),
        IconButton(
          tooltip: habitSheetChangeLabel,
          onPressed: onToggleEdit,
          icon: Icon(editing ? Icons.check : Icons.edit_outlined),
        ),
        IconButton(
          tooltip: habitSheetRemoveLabel,
          onPressed: () => actions.remove(checkIn.id),
          icon: const Icon(Icons.delete_outline),
        ),
      ],
    );
  }
}

class _SheetOfferCard extends StatelessWidget {
  const _SheetOfferCard({required this.offered});

  final Habit offered;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('habit_sheet_offer'),
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        border: Border.all(color: scheme.primary, width: 2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            habitOfferFollowsLine(offered.title),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const Text(habitOfferNotYetLine),
          const SizedBox(height: 8),
          HabitOfferButtons(offered: offered, inSheet: true),
        ],
      ),
    );
  }
}
