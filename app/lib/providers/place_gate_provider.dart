/// The rule that hides an Outcome from Next while the user is at another
/// Place (issue #55).
///
/// Hiding is on Next only. Up Next and Add to Plan keep using the Time
/// context set alone: a Place never hides an Outcome there.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/action_place_and_time_window.dart';
import '../models/place_choice.dart';
import 'current_location_provider.dart';
import 'database_provider.dart';

/// The Place each Outcome's current Action carries, keyed by Outcome id.
final currentPlacesProvider =
    StreamProvider<Map<String, ActionPlace>>((ref) {
  return ref.watch(databaseProvider).actionDao.watchCurrentPlaces();
});

/// The Place each Habit carries, keyed by Habit id (issue #1075).
///
/// A Habit is never hidden by its Place: this is what shows where it is, not
/// a gate. A Habit whose Place no longer exists is absent from the map.
final habitPlacesProvider =
    StreamProvider<Map<String, HabitPlace>>((ref) {
  return ref.watch(databaseProvider).habitDao.watchHabitPlaces();
});

/// Outcome ids whose current Action is at a Place the user is not at.
///
/// Empty when the location is unknown: with no fix, nothing is hidden by
/// place. An Outcome whose Place's area holds the point stays on Next.
final awayFromPlaceOutcomeIdsProvider = Provider<Set<String>>((ref) {
  final location = ref.watch(currentLocationProvider);
  final places = ref.watch(currentPlacesProvider).value ?? const {};
  return awayOutcomeIds(places: places, location: location);
});

/// The name to show for a Place: the Place's own name, or "Pin" for a one-time
/// pin that has none.
///
/// The same rule the clarify card's Place chip goes by, so the two surfaces
/// never name the same Place differently.
String placeDisplayName(ActionPlace place) => placeNameLabel(place.name);

/// The name to show for the Place each Outcome carries, keyed by Outcome id.
final currentPlaceNamesProvider = Provider<Map<String, String>>((ref) {
  final places = ref.watch(currentPlacesProvider).value ?? const {};
  return {
    for (final entry in places.entries)
      entry.key: placeDisplayName(entry.value),
  };
});

/// The name to show for the Place each Habit carries, keyed by Habit id.
///
/// The Place's own name, or "Pin" for a one-time pin that has none. A Habit
/// whose Place no longer exists is absent from the map.
final habitPlaceNamesProvider = Provider<Map<String, String>>((ref) {
  final places = ref.watch(habitPlacesProvider).value ?? const {};
  return {
    for (final entry in places.entries)
      entry.key: placeDisplayName(entry.value),
  };
});

/// The away rule, as a pure function of the places and the location.
///
/// An Outcome is away when the area of its Place does not hold the point.
/// The point's accuracy is ignored: inside is [PlaceArea.containsPoint].
Set<String> awayOutcomeIds({
  required Map<String, ActionPlace> places,
  required CurrentLocation location,
}) {
  switch (location) {
    case LocationPending():
    case LocationUnknown():
      return const <String>{};
    case LocationKnown(:final point):
      return {
        for (final entry in places.entries)
          if (!entry.value.area.containsPoint(
              point.latitudeDegrees, point.longitudeDegrees))
            entry.key,
      };
  }
}
