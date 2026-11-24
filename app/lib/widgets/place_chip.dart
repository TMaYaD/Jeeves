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
    // The Action says whether it carries a Place at all. Where it does not,
    // the chip stays quiet and reads nothing: the Place is named only where
    // there is one to name.
    if (action.placeId == null) {
      return _PlaceChipButton(
        outcomeId: outcomeId,
        actionId: action.id,
        label: 'Place',
        isSet: false,
      );
    }
    return _NamedPlaceChip(outcomeId: outcomeId, actionId: action.id);
  }
}

/// The chip with the Place's name on it.
class _NamedPlaceChip extends ConsumerWidget {
  const _NamedPlaceChip({required this.outcomeId, required this.actionId});

  final String outcomeId;
  final String actionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final place = ref.watch(currentPlacesProvider).value?[outcomeId];
    return _PlaceChipButton(
      outcomeId: outcomeId,
      actionId: actionId,
      label: place == null ? 'Place' : placeDisplayName(place),
      isSet: place != null,
    );
  }
}

/// The chip itself: the label, and the picker behind it.
class _PlaceChipButton extends StatelessWidget {
  const _PlaceChipButton({
    required this.outcomeId,
    required this.actionId,
    required this.label,
    required this.isSet,
  });

  final String outcomeId;
  final String actionId;
  final String label;
  final bool isSet;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const Key('place_chip'),
      borderRadius: BorderRadius.circular(4),
      onTap: () => showPlacePickerSheet(
        context,
        outcomeId: outcomeId,
        actionId: actionId,
      ),
      child: MetaChip(
        icon: Icons.place_outlined,
        label: label,
        color: isSet
            ? const Color(0xFF4A5568)
            : const Color(0xFF9CA3AF),
      ),
    );
  }
}
