/// The place page: every Outcome and Habit with a Place, grouped by the Places that are
/// near each other (issues #1090, #1094).
///
/// The list is the Next list before hiding, so an Outcome hidden because the
/// user is elsewhere is here to be found. Each row says where it stands:
/// "On Next" when the user is at its Place, "Elsewhere" when they are not.
/// A Habit with a Place is listed under it too, after the Outcomes; it is
/// never on Next, and an archived Habit is left out.
///
/// The groups are there as soon as the page opens: nobody has to choose a
/// stop first.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/habit_dao.dart' show HabitState;
import '../database/gtd_database.dart' show Habit;
import '../models/errand_route.dart';
import '../models/nearby_places.dart';
import '../models/place_area.dart';
import 'database_provider.dart';
import 'gtd_lists_provider.dart';
import 'habits_provider.dart';
import 'place_gate_provider.dart';
import 'tag_filter_provider.dart';

/// Places near each other, drawn together on the place page.
typedef PlacePageGroup = ({
  List<PlacePageSection> places,
});

/// One Place on the place page: its name, where it is, and the Outcomes and
/// Habits at it.
///
/// [rows] holds Outcomes only, so selection and errands stay Outcome-only;
/// [habits] is listed after them and is not selectable.
typedef PlacePageSection = ({
  String placeId,
  String label,
  PlaceArea area,
  List<PlacePageRow> rows,
  List<PlacePageHabitRow> habits,
});

/// A Habit on the place page, and the state it is in today (active or
/// paused; an archived Habit is not listed).
typedef PlacePageHabitRow = ({
  Habit habit,
  HabitState state,
});

/// A row on the place page: an Outcome, and where it stands.
///
/// [isOnNext] says whether the Outcome is on the Next list right now. An
/// Outcome the user is standing at but whose time is closed is not on Next,
/// so it is not marked as on Next.
typedef PlacePageRow = ({
  Todo todo,
  bool isOnNext,
});

/// A Place on the page, with the point it is grouped by.
typedef _PlaceSection = ({
  String placeId,
  String label,
  PlaceArea area,
  bool isPin,
  List<PlacePageRow> rows,
  List<PlacePageHabitRow> habits,
});

/// The Outcomes with a Place, grouped by the Places that are near each other.
final placePageGroupsProvider = StreamProvider<List<PlacePageGroup>>((ref) {
  final db = ref.watch(databaseProvider);
  final tagIds = ref.watch(tagFilterProvider);
  final places = ref.watch(currentPlacesProvider).value ?? const {};
  // "On Next" is the Next list's own answer, not a second guess at it: an
  // Outcome that the user is standing at but whose time is closed is not on
  // Next, and the marker must not say it is.
  final onNext = {
    for (final todo in ref.watch(nextProvider).value ?? const <Todo>[])
      todo.id,
  };
  // The Label filter does not apply to Habits, as on the Habits list.
  final habitPlaces = ref.watch(habitPlacesProvider).value ?? const {};
  final habitRows = ref.watch(habitListProvider).value ?? const [];
  return db.todoDao.watchNext(tagIds: tagIds).map((todos) {
    // One section per Place: a named Place, or a one-time pin of its own. A
    // pin is never a bucket of its own kind — pins at opposite ends of town
    // are not near each other.
    final sections = <String, _PlaceSection>{};
    for (final todo in todos) {
      final place = places[todo.id];
      if (place == null) continue;
      final row = (todo: todo, isOnNext: onNext.contains(todo.id));
      final section = sections[place.id];
      if (section == null) {
        sections[place.id] = (
          placeId: place.id,
          label: placeDisplayName(place),
          area: place.area,
          isPin: place.isPin,
          rows: [row],
          habits: [],
        );
      } else {
        section.rows.add(row);
      }
    }
    // Habits come after the Outcomes of their Place, oldest first. A Place
    // only Habits use still gets its section.
    for (final entry in habitRows) {
      if (entry.state == HabitState.archived) continue;
      final place = habitPlaces[entry.habit.id];
      if (place == null) continue;
      final habitRow = (habit: entry.habit, state: entry.state);
      final section = sections[place.id];
      if (section == null) {
        sections[place.id] = (
          placeId: place.id,
          label: placeDisplayName(place),
          area: place.area,
          isPin: place.isPin,
          rows: [],
          habits: [habitRow],
        );
      } else {
        section.habits.add(habitRow);
      }
    }
    final nearby = groupNearby(
      sections.values.toList(),
      areaOf: (section) => section.area,
      compare: _compareSections,
    );
    return [
      for (final group in nearby)
        (places: [
          for (final section in group)
            (
              placeId: section.placeId,
              label: section.label,
              area: section.area,
              rows: section.rows,
              habits: section.habits,
            ),
        ]),
    ];
  });
});

/// Named Places come first, in name order; then the pins, in name order too.
int _compareSections(_PlaceSection a, _PlaceSection b) {
  if (a.isPin != b.isPin) return a.isPin ? 1 : -1;
  final byLabel = a.label.compareTo(b.label);
  if (byLabel != 0) return byLabel;
  return a.placeId.compareTo(b.placeId);
}

/// The stops of an errand: the Places that have at least one of the chosen
/// Outcomes, one stop per Place, in the order the page draws them.
///
/// The result is one list per group of nearby Places, and groups with no
/// chosen Outcome are left out. The order is the page order, which is not a
/// route: Jeeves does not plan routes.
List<List<ErrandStop>> errandStopsFrom(
  List<PlacePageGroup> groups,
  Set<String> selectedOutcomeIds,
) {
  final stopsByGroup = <List<ErrandStop>>[];
  for (final group in groups) {
    final stops = [
      for (final place in group.places)
        if (place.rows.any((row) => selectedOutcomeIds.contains(row.todo.id)))
          ErrandStop(
            placeId: place.placeId,
            label: place.label,
            area: place.area,
          ),
    ];
    if (stops.isNotEmpty) stopsByGroup.add(stops);
  }
  return stopsByGroup;
}
