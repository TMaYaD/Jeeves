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
///
/// To the nearest step, not to the one below: a radius of 175 m is nearer
/// 200 m than 150 m, and the slider says so.
int nearestPlaceAreaStep(int meters) {
  final offset = (meters - PlaceArea.minRadiusMeters) / placeAreaStepMeters;
  final steps = offset.round().clamp(0, placeAreaSteps);
  return PlaceArea.minRadiusMeters + steps * placeAreaStepMeters;
}

/// The slider for a Place's area.
class PlaceAreaSlider extends StatelessWidget {
  const PlaceAreaSlider({
    super.key,
    required this.radiusMeters,
    required this.onChanged,
  });

  /// The radius the Place has, in metres.
  ///
  /// The handle sits at the step nearest it, because the slider runs in
  /// steps; the text says the radius itself, so a radius that came from
  /// another device is neither hidden nor rewritten.
  final int radiusMeters;

  /// Called with the new radius, in metres, when the user moves the handle.
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final step = nearestPlaceAreaStep(radiusMeters);
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
          value: step.toDouble(),
          min: PlaceArea.minRadiusMeters.toDouble(),
          max: PlaceArea.maxRadiusMeters.toDouble(),
          divisions: placeAreaSteps,
          label: '$step m',
          onChanged: (value) => onChanged(value.round()),
        ),
      ],
    );
  }
}
