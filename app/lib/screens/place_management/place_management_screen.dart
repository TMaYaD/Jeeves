/// Settings → Manage → Places: the user's named places (issue #55).
///
/// Each row names a Place, its area and how many live Actions use it.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/places_provider.dart';
import '../../widgets/app_title_bar/app_title_bar.dart';
import '../../widgets/place_editor_sheet.dart';

/// Jeeves's line for an empty list of places — a pool.
const placesEmptyPool = <String>[
  'No places yet, sir.',
  'You have named no places as yet, sir.',
  'The place list is empty, sir.',
];

final _placesEmptyRandom = Random();

/// Draws Jeeves's line for an empty list of places. Pass [seed] in tests for
/// a deterministic draw; null in production so each visit draws afresh.
String placesEmptyLine({int? seed}) {
  final rng = seed == null ? _placesEmptyRandom : Random(seed);
  return placesEmptyPool[rng.nextInt(placesEmptyPool.length)];
}

/// The list of the user's named places.
class PlaceManagementScreen extends ConsumerStatefulWidget {
  const PlaceManagementScreen({super.key});

  @override
  ConsumerState<PlaceManagementScreen> createState() =>
      _PlaceManagementScreenState();
}

class _PlaceManagementScreenState extends ConsumerState<PlaceManagementScreen> {
  /// The line for an empty list, drawn once: a line that changed on every
  /// rebuild would read as if Jeeves kept changing its mind.
  late final String _emptyLine = placesEmptyLine();

  @override
  Widget build(BuildContext context) {
    final places = ref.watch(namedPlacesWithUseCountProvider);
    return Scaffold(
      appBar: AppTitleBar(
        title: 'Places',
        pageActions: [
          AppTitleBarAction(
            key: const Key('place_management_add'),
            icon: Icons.add,
            label: 'New place',
            onPressed: () => showPlaceEditorSheet(context),
          ),
        ],
      ),
      backgroundColor: Colors.white,
      body: places.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, s) =>
            const Center(child: Text('Could not load your places')),
        data: (rows) {
          if (rows.isEmpty) {
            return Center(
              child: Text(
                _emptyLine,
                key: const Key('place_management_empty'),
                style: const TextStyle(color: Color(0xFF9CA3AF)),
              ),
            );
          }
          // The list is by name here: the picker is where the order of use
          // matters.
          final byName = [...rows]..sort((a, b) => a.name.compareTo(b.name));
          return ListView.builder(
            itemCount: byName.length,
            itemBuilder: (_, i) {
              final row = byName[i];
              return ListTile(
                key: Key('place_management_row_${row.id}'),
                title: Text(
                  row.name,
                  style: const TextStyle(
                      fontWeight: FontWeight.w500, color: Color(0xFF374151)),
                ),
                subtitle: Text(
                  row.hoursLabel == null
                      ? '${row.area.radiusMeters} m'
                      : '${row.area.radiusMeters} m · ${row.hoursLabel}',
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
                ),
                trailing: Text(
                  '${row.useCount}',
                  style: const TextStyle(color: Color(0xFF9CA3AF)),
                ),
                onTap: () => showPlaceEditorSheet(context, place: row),
              );
            },
          );
        },
      ),
    );
  }
}
