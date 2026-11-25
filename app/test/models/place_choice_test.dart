/// Unit tests for the Place labels (issue #1078).
///
/// Two surfaces name a Place — the Outcome's Place chip and the clarify
/// card's — and they must never disagree about what a pin reads as.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/models/place_area.dart';
import 'package:jeeves/models/place_choice.dart';

PlaceArea _area() => PlaceArea.create(
      latitudeDegrees: 52.3702,
      longitudeDegrees: 4.8952,
      radiusMeters: 150,
    )!;

void main() {
  group('placeNameLabel', () {
    test('the Place\'s own name', () {
      expect(placeNameLabel('Hardware store'), 'Hardware store');
    });

    test('a pin with no name reads "Pin"', () {
      expect(placeNameLabel(null), 'Pin');
      expect(placeNameLabel(''), 'Pin');
      expect(placeNameLabel('   '), 'Pin');
    });

    test('the name is trimmed', () {
      expect(placeNameLabel('  Hardware store  '), 'Hardware store');
    });
  });

  group('placeDraftLabel', () {
    test('a named Place by its name', () {
      expect(
        placeDraftLabel(const NamedPlaceDraft('p1', 'Hardware store')),
        'Hardware store',
      );
    });

    test('a pin by the short name it may carry', () {
      expect(
        placeDraftLabel(PinDraft(area: _area(), name: 'Post office on Mill St')),
        'Post office on Mill St',
      );
    });

    test('a pin with no name reads "Pin"', () {
      expect(placeDraftLabel(PinDraft(area: _area())), 'Pin');
      expect(
        placeDraftLabel(PinDraft(area: _area(), name: '   ')),
        'Pin',
      );
    });
  });
}
