/// One row of the Habit list, and the Check-in controls it shares with the
/// detail's Today card.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../database/daos/habit_dao.dart';
import '../../database/gtd_database.dart' show Habit;
import '../../models/habit_progress.dart';
import '../../providers/habit_check_ins_provider.dart';
import '../../providers/habit_progress_provider.dart';
import '../../providers/habit_stack_offer_provider.dart';
import '../../widgets/habit_check_in_mark.dart';
import 'habit_amount_entry_sheet.dart';
import 'habit_copy.dart';
import 'habit_routes.dart';

/// A binary Habit's mark checks in or undoes; a measurable Habit's mark opens
/// the entry sheet, filled or not.
Future<void> tapHabitMark(
  BuildContext context,
  WidgetRef ref, {
  required Habit habit,
  required HabitCheckInMarkState markState,
  required bool isMeasurable,
}) async {
  if (isMeasurable) return showHabitAmountEntrySheet(context, habit);
  final habitId = habit.id;
  final actions = ref.read(habitCheckInsProvider.notifier);
  switch (markState) {
    case HabitCheckInMarkState.open:
      await actions.checkIn(habitId);
      ref.read(habitStackOfferProvider.notifier).checkedIn(habitId);
    case HabitCheckInMarkState.done:
      await actions.removeLatestOfToday(habitId);
    case HabitCheckInMarkState.addAmount:
    case HabitCheckInMarkState.notDue:
    case HabitCheckInMarkState.paused:
      break;
  }
}

/// "Right ho": a binary Habit is checked in at once and becomes the new source
/// of the offer (until #405, that includes one with an estimate); a measurable
/// one opens its entry sheet, after closing a sheet that is open.
Future<void> acceptHabitOffer(
  BuildContext context,
  WidgetRef ref,
  Habit offered, {
  bool closeSheet = false,
}) async {
  final isMeasurable =
      ref.read(habitTodayEntriesProvider(offered.id))?.commitment?.isMeasurable ??
          false;
  final navigator = Navigator.of(context);
  if (isMeasurable) {
    if (closeSheet) navigator.pop();
    await showHabitAmountEntrySheet(navigator.context, offered);
    return;
  }
  await ref.read(habitCheckInsProvider.notifier).checkIn(offered.id);
  ref.read(habitStackOfferProvider.notifier).checkedIn(offered.id);
}

/// "Right ho" (filled) and "Not now" (text).
class HabitOfferButtons extends ConsumerWidget {
  const HabitOfferButtons({super.key, required this.offered, this.inSheet = false});

  final Habit offered;
  final bool inSheet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FilledButton(
          key: Key('habit_offer_accept_${offered.id}'),
          onPressed: () =>
              acceptHabitOffer(context, ref, offered, closeSheet: inSheet),
          child: const Text(habitOfferAcceptLabel),
        ),
        const SizedBox(width: 8),
        TextButton(
          key: Key('habit_offer_dismiss_${offered.id}'),
          onPressed: () => ref.read(habitStackOfferProvider.notifier).dismiss(),
          child: const Text(habitOfferDismissLabel),
        ),
      ],
    );
  }
}

/// The Check-in mark of [habit], wired to its progress and labelled.
class HabitMarkButton extends ConsumerWidget {
  const HabitMarkButton({
    super.key,
    required this.habit,
    this.onTodayCard = false,
  });

  final Habit habit;
  final bool onTodayCard;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(habitProgressProvider(habit.id));
    final entries = ref.watch(habitTodayEntriesProvider(habit.id));
    if (progress == null) return const SizedBox(width: 48, height: 48);
    final isMeasurable = entries?.commitment?.isMeasurable ?? false;
    final markState = habitMarkState(progress.todayState, isMeasurable);
    return Semantics(
      label: habitMarkLabel(
        title: habit.title,
        isMeasurable: isMeasurable,
        isDone: markState == HabitCheckInMarkState.done,
        onTodayCard: onTodayCard,
      ),
      button: true,
      excludeSemantics: true,
      child: HabitCheckInMark(
        key: Key('habit_mark_${habit.id}${onTodayCard ? '_today' : ''}'),
        state: markState,
        onTap: () => tapHabitMark(
          context,
          ref,
          habit: habit,
          markState: markState,
          isMeasurable: isMeasurable,
        ),
      ),
    );
  }
}

/// Ten-or-fewer little rings, one per unit of the target.
class HabitPips extends StatelessWidget {
  const HabitPips({super.key, required this.target, required this.done});

  final int target;
  final double done;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Wrap(
      spacing: 3,
      children: [
        for (var i = 0; i < target; i++)
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i < done ? primary : null,
              border: Border.all(color: primary, width: 2),
            ),
          ),
      ],
    );
  }
}

/// The streak number, its label and, for N a week or month, the period line.
class HabitNumberColumn extends StatelessWidget {
  const HabitNumberColumn({
    super.key,
    required this.progress,
    required this.entries,
  });

  final HabitProgress progress;
  final HabitTodayEntries? entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dimmed = progress.todayState == HabitTodayState.notDue;
    final color = theme.colorScheme.primary.withValues(alpha: dimmed ? 0.45 : 1);
    final commitment = entries?.commitment;
    final period = habitPeriodLine(progress, commitment);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          '${progress.currentStreak}',
          style: theme.textTheme.titleLarge?.copyWith(color: color),
        ),
        Text(habitStreakLabel(commitment), style: theme.textTheme.labelSmall),
        if (period != null)
          Text(
            period,
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
      ],
    );
  }
}

class HabitRow extends ConsumerWidget {
  const HabitRow({
    super.key,
    required this.habit,
    required this.state,
    required this.selected,
  });

  final Habit habit;
  final HabitState state;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inactive = state != HabitState.active;
    final scheme = Theme.of(context).colorScheme;
    final progress = ref.watch(habitProgressProvider(habit.id));
    final entries = ref.watch(habitTodayEntriesProvider(habit.id));
    final stateText = progress == null
        ? null
        : habitRowStateText(
            progress: progress,
            commitment: entries?.commitment,
            todaysCheckIns: entries?.checkIns ?? const [],
          );
    final offerSource = ref.watch(offeredHabitProvider)?.id == habit.id
        ? ref.watch(offerSourceHabitProvider)
        : null;
    final anchorText = habitAnchorSummary(habit);
    final secondLine = [
      ?stateText,
      ?anchorText,
    ].join(' · ');
    final showPips =
        progress != null &&
        !inactive &&
        habitShowsPips(progress.targetAmount) &&
        (entries?.commitment?.isMeasurable ?? false);
    final tile = ListTile(
      key: Key('habit_row_${habit.id}'),
      selected: selected,
      title: Text(
        habit.title,
        style: inactive ? TextStyle(color: scheme.onSurfaceVariant) : null,
      ),
      subtitle: secondLine.isEmpty && !showPips && offerSource == null
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (secondLine.isNotEmpty)
                  Text(secondLine, key: Key('habit_state_${habit.id}')),
                if (showPips)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: HabitPips(
                      target: progress.targetAmount!.round(),
                      done: progress.todayTotalAmount ?? 0,
                    ),
                  ),
                if (offerSource != null)
                  _OfferBody(
                    source: offerSource,
                    offered: habit,
                    offeredUnit: progress?.unitLabel,
                  ),
              ],
            ),
      trailing: progress == null
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!inactive)
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: HabitNumberColumn(
                      progress: progress,
                      entries: entries,
                    ),
                  ),
                HabitMarkButton(habit: habit),
              ],
            ),
      onTap: () => openHabitDetail(context, habit.id),
    );
    if (offerSource == null) return tile;
    return Container(
      key: Key('habit_offer_${habit.id}'),
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        border: Border.all(color: scheme.primary, width: 2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: tile,
    );
  }
}

class _OfferBody extends StatelessWidget {
  const _OfferBody({
    required this.source,
    required this.offered,
    required this.offeredUnit,
  });

  final Habit source;
  final Habit offered;
  final String? offeredUnit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            habitOfferLine,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            habitOfferSubLine(
              sourceTitle: source.title,
              offeredUnit: offeredUnit,
            ),
            key: Key('habit_offer_subline_${offered.id}'),
          ),
          const SizedBox(height: 8),
          HabitOfferButtons(offered: offered),
        ],
      ),
    );
  }
}

/// A one-line description of where [habit] sits in the day, or null.
String? habitAnchorSummary(Habit habit) {
  switch (HabitAnchorKind.tryParse(habit.anchorKind)) {
    case HabitAnchorKind.partOfDay:
      return habit.anchorPartOfDay;
    case HabitAnchorKind.clockTime:
      return habit.anchorClockTime == null
          ? null
          : 'At ${habit.anchorClockTime}';
    case HabitAnchorKind.afterHabit:
      return 'After another Habit';
    case HabitAnchorKind.beforeHabit:
      return 'Before another Habit';
    case HabitAnchorKind.none:
    case null:
      return null;
  }
}

/// The detail's Today card: the mark, today's date and the state.
class HabitTodayCard extends ConsumerWidget {
  const HabitTodayCard({super.key, required this.habit, required this.today});

  final Habit habit;
  final DateTime today;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(habitProgressProvider(habit.id));
    final entries = ref.watch(habitTodayEntriesProvider(habit.id));
    if (progress == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final commitment = entries?.commitment;
    final showPips =
        habitShowsPips(progress.targetAmount) &&
        (commitment?.isMeasurable ?? false);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        key: const Key('habit_today_card'),
        children: [
          HabitMarkButton(habit: habit, onTodayCard: true),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Today · ${habitTodayDateText(today)}',
                  style: theme.textTheme.labelMedium,
                ),
                Text(
                  habitTodayCardState(
                    progress: progress,
                    commitment: commitment,
                    todaysCheckIns: entries?.checkIns ?? const [],
                  ),
                  key: const Key('habit_today_state'),
                ),
              ],
            ),
          ),
          if (showPips)
            HabitPips(
              target: progress.targetAmount!.round(),
              done: progress.todayTotalAmount ?? 0,
            ),
        ],
      ),
    );
  }
}
