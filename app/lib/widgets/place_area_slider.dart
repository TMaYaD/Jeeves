/// The slider for a Place's area: how far from the point the user still counts
/// as being there (issue #55).
///
/// The area runs from 50 m to 2 km, in steps of 50 m. A new Place takes
/// 150 m.
library;

import 'package:flutter/material.dart';

import '../models/place_area.dart';

/// The step between two slider positions, in metres.
const int placeAreaStepMeters = 50;

/// The number of steps between the smallest and the largest radius.
const int placeAreaSteps =
    (PlaceArea.maxRadiusMeters - PlaceArea.minRadiusMeters) ~/ placeAreaStepMeters;

/// The radius nearest to [meters] that the slider can show.
int nearestPlaceAreaStep(int meters) {
  final steps = (meters - PlaceArea.minRadiusMeters) ~/ placeAreaStepMeters;
  return PlaceArea.minRadiusMeters +
      steps.clamp(0, placeAreaSteps) * placeAreaStepMeters;
}

/// The slider for a Place's area.
class PlaceAreaSlider extends StatelessWidget {
  const PlaceAreaSlider({
    super.key,
    required this.radiusMeters,
    required this.onChanged,
  });

  /// The radius the slider shows, in metres.
  final int radiusMeters;

  /// Called with the new radius, in metres.
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Area', style: TextStyle(fontWeight: FontWeight.w500)),
            const Spacer(),
            Text(
              '$radiusMeters m',
              style: const TextStyle(color: Color(0xFF6B7280)),
            ),
          ],
        ),
        Slider(
          key: const Key('place_area_slider'),
          value: radiusMeters.toDouble(),
          min: PlaceArea.minRadiusMeters.toDouble(),
          max: PlaceArea.maxRadiusMeters.toDouble(),
          divisions: placeAreaSteps,
          label: '$radiusMeters m',
          onChanged: (value) => onChanged(value.round()),
        ),
      ],
    );
  }
}
