/// The place page: every Outcome with a Place, grouped (issue #55).
///
/// The list is the Next list before hiding, so an Outcome hidden because the
/// user is elsewhere is here to be found. Each row says where it stands:
/// "On Next" when the user is at its Place, "Elsewhere" when they are not.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database_provider.dart';
import 'gtd_lists_provider.dart';
import 'place_gate_provider.dart';
import 'tag_filter_provider.dart';

/// A group of Outcomes on the place page: one named Place, or the pins.
typedef PlacePageGroup = ({
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

/// The Outcomes with a Place, grouped by Place in name order, then the pins.
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
    final named = <String, ({String name, List<PlacePageRow> rows})>{};
    final pins = <PlacePageRow>[];
    for (final todo in todos) {
      final place = places[todo.id];
      if (place == null) continue;
      final row = (todo: todo, isOnNext: onNext.contains(todo.id));
      if (place.isPin) {
        pins.add(row);
        continue;
      }
      final group = named[place.id];
      if (group == null) {
        named[place.id] = (name: place.name ?? '', rows: [row]);
      } else {
        group.rows.add(row);
      }
    }
    final groups = named.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return [
      for (final group in groups)
        (label: group.name, rows: group.rows),
      if (pins.isNotEmpty) (label: 'Pins', rows: pins),
    ];
  });
});
