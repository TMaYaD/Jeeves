/// The Habit list: active Habits in stack order, then paused, then archived.
/// At 840 px or wider the selected Habit's detail sits beside it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../database/daos/habit_dao.dart';
import '../../database/gtd_database.dart' show Habit;
import '../../models/habit_progress.dart';
import '../../providers/habit_progress_provider.dart';
import '../../providers/habits_provider.dart';
import '../../widgets/state_surfaces.dart';
import 'habit_copy.dart';
import 'habit_detail_pane.dart';
import 'habit_routes.dart';

/// The Habits shell route.
class HabitsScreen extends ConsumerWidget {
  const HabitsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wide =
        MediaQuery.sizeOf(context).width >= habitsWideBreakpointWidth;
    final query = GoRouterState.of(context).uri.queryParameters;
    final selected = query['habit'];
    final list = _HabitList(selectedHabitId: wide ? selected : null);
    if (!wide) return list;
    return Row(
      children: [
        SizedBox(width: 360, child: list),
        const VerticalDivider(width: 1),
        Expanded(
          child: selected == null
              ? const Center(child: Text(habitsDetailPlaceholder))
              : HabitDetailPane(
                  key: ValueKey('habit-pane-$selected'),
                  habitId: selected == 'new' ? null : selected,
                  showNewBanner: query['new'] == '1',
                  embedded: true,
                ),
        ),
      ],
    );
  }
}

class _HabitList extends ConsumerWidget {
  const _HabitList({required this.selectedHabitId});

  final String? selectedHabitId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rowsAsync = ref.watch(habitListProvider);
    final chains = ref.watch(habitStackChainsProvider);
    final forToday = ref.watch(habitsForTodayProvider);
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('habits_add'),
        onPressed: () => openHabitDetail(context, null),
        icon: const Icon(Icons.add),
        label: const Text(habitsAddLabel),
      ),
      body: rowsAsync.when(
        loading: () => const LoadingSurface(),
        error: (_, _) => const ErrorSurface(),
        data: (rows) {
          if (rows.isEmpty) {
            return const EmptySurface(
              icon: Icons.repeat,
              title: habitsEmptyTitle,
              subtitle: habitsEmptyLine,
            );
          }
          final activeIds = {
            for (final row in rows)
              if (row.state == HabitState.active) row.habit.id,
          };
          final active = [
            for (final chain in chains)
              for (final habit in chain)
                if (activeIds.contains(habit.id)) habit,
          ];
          final paused = [
            for (final row in rows)
              if (row.state == HabitState.paused) row.habit,
          ];
          final archived = [
            for (final row in rows)
              if (row.state == HabitState.archived) row.habit,
          ];
          final note = _todayNote(ref, active, forToday);
          final children = <Widget>[
            if (active.isEmpty)
              const _Note(habitsOnlyInactiveLine, key: Key('habits_only_inactive')),
            if (note != null) _Note(note, key: const Key('habits_today_note')),
            for (final habit in active)
              _HabitRow(
                  habit: habit,
                  state: HabitState.active,
                  selected: habit.id == selectedHabitId),
            if (paused.isNotEmpty) const _SectionHeader('Paused'),
            for (final habit in paused)
              _HabitRow(
                  habit: habit,
                  state: HabitState.paused,
                  selected: habit.id == selectedHabitId),
            if (archived.isNotEmpty) const _SectionHeader('Archived'),
            for (final habit in archived)
              _HabitRow(
                  habit: habit,
                  state: HabitState.archived,
                  selected: habit.id == selectedHabitId),
          ];
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 96),
            itemCount: children.length,
            itemBuilder: (_, i) => children[i],
          );
        },
      ),
    );
  }

  /// "All done" or "nothing due", from the streak engine's for-today set.
  String? _todayNote(WidgetRef ref, List<Habit> active, Set<String> forToday) {
    if (active.isEmpty) return null;
    if (forToday.isEmpty) return habitsNothingDueLine;
    final allDone = forToday.every(
        (id) => ref.watch(habitProgressProvider(id))?.todayState ==
            HabitTodayState.done);
    return allDone ? habitsAllDoneLine : null;
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(text,
            style: TextStyle(color: Theme.of(context).hintColor)),
      );
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(text.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall),
      );
}

class _HabitRow extends StatelessWidget {
  const _HabitRow(
      {required this.habit, required this.state, required this.selected});

  final Habit habit;
  final HabitState state;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final inactive = state != HabitState.active;
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      key: Key('habit_row_${habit.id}'),
      selected: selected,
      title: Text(
        habit.title,
        style: inactive ? TextStyle(color: scheme.onSurfaceVariant) : null,
      ),
      subtitle: habitAnchorSummary(habit) == null
          ? null
          : Text(habitAnchorSummary(habit)!),
      onTap: () => openHabitDetail(context, habit.id),
    );
  }
}

/// A one-line description of where [habit] sits in the day, or null.
String? habitAnchorSummary(Habit habit) {
  switch (HabitAnchorKind.tryParse(habit.anchorKind)) {
    case HabitAnchorKind.partOfDay:
      return habit.anchorPartOfDay;
    case HabitAnchorKind.clockTime:
      return habit.anchorClockTime == null ? null : 'At ${habit.anchorClockTime}';
    case HabitAnchorKind.afterHabit:
      return 'After another Habit';
    case HabitAnchorKind.beforeHabit:
      return 'Before another Habit';
    case HabitAnchorKind.none:
    case null:
      return null;
  }
}
