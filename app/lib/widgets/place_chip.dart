/// The chip showing the Place an Outcome's current Action is at (issue #55).
///
/// A quiet "Place" when the Action carries none, the Place's own name when it
/// carries one — and "Pin" for a one-time pin that has no name of its own.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/place_area.dart';
import '../models/place_choice.dart';
import '../providers/location_permission_flow.dart';
import '../providers/location_source_provider.dart';
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
    // Where the current Action carries no Place, the chip stays quiet and
    // reads nothing: the Place is named only where there is one to name.
    return _PlaceChipButton(
      outcomeId: outcomeId,
      actionId: action.id,
      label: place == null ? 'Place' : placeDisplayName(place),
      isSet: place != null,
    );
  }
}

/// The chip itself: the label, and the picker behind it.
///
/// The picker answers with the choice the user made; the chip applies it to
/// the Outcome's current Action. The write is guarded in
/// [TaskDetailNotifier]: a choice made for an Action that is no longer the
/// current one is dropped.
class _PlaceChipButton extends ConsumerStatefulWidget {
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
  ConsumerState<_PlaceChipButton> createState() => _PlaceChipButtonState();
}

class _PlaceChipButtonState extends ConsumerState<_PlaceChipButton> {
  Future<void> _choosePlace() async {
    // The Action the choice belongs to: the one that was current when the
    // picker opened. A successor that arrives while the picker is up is a
    // different Action, and the guard in [TaskDetailNotifier] drops the choice
    // rather than landing it on the successor the user never saw.
    final outcomeId = widget.outcomeId;
    final actionId = widget.actionId;
    // "Clear place" is on offer only when there is a Place to clear.
    final canClear =
        ref.read(currentPlacesProvider).value?[outcomeId] != null;
    final choice = await showPlacePickerSheet(context, canClear: canClear);
    if (choice == null || !mounted) return;
    switch (choice) {
      case NamedPlaceDraft(:final placeId):
        await ref.read(taskDetailNotifierProvider(outcomeId)).setNamedPlace(
              actionId: actionId,
              placeId: placeId,
            );
      case PinDraft(:final area, :final name):
        await _dropPin(
          outcomeId: outcomeId,
          actionId: actionId,
          area: area,
          name: name,
        );
      case ClearPlaceChoice():
        await ref
            .read(taskDetailNotifierProvider(outcomeId))
            .clearPlace(actionId: actionId);
    }
  }

  Future<void> _dropPin({
    required String outcomeId,
    required String actionId,
    required PlaceArea area,
    required String? name,
  }) async {
    final dropped = await ref.read(taskDetailNotifierProvider(outcomeId)).setPin(
          actionId: actionId,
          area: area,
          name: name,
        );
    if (!dropped || !mounted) return;
    // A pin is a Place too: the first one saved may ask for the location. A
    // pin that was not written — the Action is no longer the current one —
    // is no Place saved, so it asks nothing.
    await askForLocationAfterFirstSave(
        context, ref.read(locationSourceProvider));
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const Key('place_chip'),
      borderRadius: BorderRadius.circular(4),
      onTap: _choosePlace,
      child: MetaChip(
        icon: Icons.place_outlined,
        label: widget.label,
        color: widget.isSet
            ? const Color(0xFF4A5568)
            : const Color(0xFF9CA3AF),
      ),
    );
  }
}
