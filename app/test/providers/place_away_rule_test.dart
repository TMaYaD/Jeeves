/// The away rule (issue #55).
///
/// An Outcome is away when the area of its Place does not hold the point —
/// and never away while the location is unknown.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/models/place_area.dart';
import 'package:jeeves/providers/current_location_provider.dart';
import 'package:jeeves/providers/place_gate_provider.dart';

void main() {
  final home = (
    id: 'p1',
    area: PlaceArea.create(
      latitudeDegrees: 52.3702,
      longitudeDegrees: 4.8952,
      radiusMeters: 150,
    )!,
    name: 'Home',
    isPin: false,
  );

  test('nothing is away while the location is unknown', () {
    expect(
      awayOutcomeIds(
        places: {'o1': home},
        location: const LocationUnknown(),
      ),
      isEmpty,
    );
    expect(
      awayOutcomeIds(
        places: {'o1': home},
        location: const LocationPending(),
      ),
      isEmpty,
    );
  });

  test('an Outcome whose Place holds the point is not away', () {
    expect(
      awayOutcomeIds(
        places: {'o1': home},
        location: const LocationKnown((
          latitudeDegrees: 52.3703,
          longitudeDegrees: 4.8953,
        )),
      ),
      isEmpty,
    );
  });

  test('an Outcome whose Place does not hold the point is away', () {
    expect(
      awayOutcomeIds(
        places: {'o1': home},
        location: const LocationKnown((
          latitudeDegrees: 52.0800,
          longitudeDegrees: 4.3000,
        )),
      ),
      {'o1'},
    );
  });

  test('a pin gates an Outcome like any other Place', () {
    final pin = (
      id: 'p2',
      area: home.area,
      name: null,
      isPin: true,
    );
    expect(
      awayOutcomeIds(
        places: {'o1': pin},
        location: const LocationKnown((
          latitudeDegrees: 52.0800,
          longitudeDegrees: 4.3000,
        )),
      ),
      {'o1'},
    );
  });
}
