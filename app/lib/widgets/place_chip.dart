/// The chip showing the Place an Outcome's current Action is at (issue #55).
///
/// A quiet "Place" when the Action carries none, the Place's own name when it
/// carries one — and "Pin" for a one-time pin that has no name of its own.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/place_gate_provider.dart';
import '../providers/task_detail_provider.dart';
import 'meta_chip.dart';
import 'place_picker_sheet.dart';

/// The Place chip of an Outcome.
class PlaceChip extends ConsumerWidget {
  const PlaceChip({super.key, required this.outcomeId});

  final String outcomeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final action = ref.watch(currentActionProvider(outcomeId)).asData?.value;
    if (action == null) return const SizedBox.shrink();
    final place = ref.watch(currentPlacesProvider).value?[outcomeId];
    final label = place == null ? 'Place' : placeDisplayName(place);
    return InkWell(
      key: const Key('place_chip'),
      borderRadius: BorderRadius.circular(4),
      onTap: () => showPlacePickerSheet(
        context,
        outcomeId: outcomeId,
        actionId: action.id,
      ),
      child: MetaChip(
        icon: Icons.place_outlined,
        label: label,
        color: place == null
            ? const Color(0xFF9CA3AF)
            : const Color(0xFF4A5568),
      ),
    );
  }
}
