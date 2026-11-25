/// The place page: every Outcome with a Place, grouped by the Places that are
/// near each other (issue #1090).
///
/// The list is the Next list before hiding, so an Outcome hidden because the
/// user is elsewhere is here to be found. Each row says where it stands:
/// "On Next" when the user is at its Place, "Elsewhere" when they are not.
///
/// The groups are there as soon as the page opens: nobody has to choose a
/// stop first.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/nearby_places.dart';
import '../models/place_area.dart';
import 'database_provider.dart';
import 'gtd_lists_provider.dart';
import 'place_gate_provider.dart';
import 'tag_filter_provider.dart';

/// Places near each other, drawn together on the place page.
typedef PlacePageGroup = ({
  List<PlacePageSection> places,
});

/// One Place on the place page: its name, and the Outcomes at it.
typedef PlacePageSection = ({
  String placeId,
  String label,
  List<PlacePageRow> rows,
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
        );
      } else {
        section.rows.add(row);
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
              rows: section.rows,
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
