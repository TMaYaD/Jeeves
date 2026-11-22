/// "Add a check-in, sir?" — the sheet asked at every Stop of a Focus on a
/// Habit (issue #405).
///
/// Jeeves never adds a Check-in by himself: "Very good" writes one for the
/// calendar day (with the stepper's amount for a measurable Habit) and sets
/// the Habit as the source of the next-in-stack offer; "Not now" and
/// dismissing the sheet write nothing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../database/gtd_database.dart' show Habit;
import '../../providers/habit_check_ins_provider.dart';
import '../../providers/habit_progress_provider.dart';
import '../../providers/habit_stack_offer_provider.dart';
import 'habit_copy.dart';

/// Opens the sheet for [habit], which has [minutesLogged] minutes of Focus.
Future<void> showHabitFocusCheckInSheet(
  BuildContext context,
  Habit habit, {
  required int minutesLogged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) =>
        HabitFocusCheckInSheet(habit: habit, minutesLogged: minutesLogged),
  );
}

class HabitFocusCheckInSheet extends ConsumerStatefulWidget {
  const HabitFocusCheckInSheet({
    super.key,
    required this.habit,
    required this.minutesLogged,
  });

  final Habit habit;
  final int minutesLogged;

  @override
  ConsumerState<HabitFocusCheckInSheet> createState() =>
      _HabitFocusCheckInSheetState();
}

class _HabitFocusCheckInSheetState
    extends ConsumerState<HabitFocusCheckInSheet> {
  int _amount = 1;
  bool _saving = false;

  Future<void> _veryGood({required bool measurable}) async {
    if (_saving) return;
    setState(() => _saving = true);
    // Read before awaiting: the sheet closes as the write lands.
    final actions = ref.read(habitCheckInsProvider.notifier);
    final offer = ref.read(habitStackOfferProvider.notifier);
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    try {
      await actions.checkIn(
        widget.habit.id,
        amount: measurable ? _amount.toDouble() : null,
      );
    } catch (_) {
      // Nothing was written: let the user try again.
      if (mounted) setState(() => _saving = false);
      rethrow;
    }
    offer.checkedIn(widget.habit.id);
    // Pop only while this sheet is still the current route (it may have been
    // dismissed while the write was in flight).
    if (mounted && (route?.isCurrent ?? false)) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final progress = ref.watch(habitProgressProvider(widget.habit.id));
    final entries = ref.watch(habitTodayEntriesProvider(widget.habit.id));
    final measurable = entries?.commitment?.isMeasurable ?? false;
    final title = widget.habit.title;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          24,
          0,
          24,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          key: const Key('habit_focus_check_in_sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.repeat, size: 16, color: scheme.primary),
                const SizedBox(width: 4),
                Text(
                  habitFocusOverline,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: scheme.primary),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              habitFocusCheckInTitle,
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              measurable
                  ? habitFocusCheckInMeasurableLine(
                      title, widget.minutesLogged)
                  : habitFocusCheckInBinaryLine(title, widget.minutesLogged),
              key: const Key('habit_focus_check_in_line'),
            ),
            if (measurable) ...[
              const SizedBox(height: 12),
              Text(
                habitFocusCheckInStepperLabel(progress?.unitLabel),
                style: theme.textTheme.labelMedium,
              ),
              Row(
                children: [
                  IconButton(
                    tooltip: habitSheetLessLabel,
                    onPressed: _amount > 1
                        ? () => setState(() => _amount--)
                        : null,
                    icon: const Icon(Icons.remove),
                  ),
                  Text(
                    '$_amount',
                    key: const Key('habit_focus_check_in_stepper'),
                    style: theme.textTheme.titleMedium,
                  ),
                  IconButton(
                    tooltip: habitSheetMoreLabel,
                    onPressed: () => setState(() => _amount++),
                    icon: const Icon(Icons.add),
                  ),
                  if (progress != null && progress.targetAmount != null)
                    Expanded(
                      child: Text(
                        habitFocusCheckInSoFarLine(
                          progress.todayTotalAmount ?? 0,
                          progress.targetAmount!,
                        ),
                        key: const Key('habit_focus_check_in_so_far'),
                        textAlign: TextAlign.end,
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const Key('habit_focus_check_in_not_now'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text(habitFocusCheckInNotNowLabel),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    key: const Key('habit_focus_check_in_yes'),
                    // Until the Habit's commitment has loaded, whether this is
                    // a measurable Habit is unknown: a binary Check-in would
                    // be written for a measurable one.
                    onPressed: entries == null || _saving
                        ? null
                        : () => _veryGood(measurable: measurable),
                    child: const Text(habitFocusCheckInYesLabel),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
