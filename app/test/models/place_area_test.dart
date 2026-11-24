import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/place_area.dart';

void main() {
  // The centre of every area in these tests: a point on a whole degree, so
  // the microdegree rounding lands exactly on it.
  const centreLatitude = 52.0;
  const centreLongitude = 13.0;

  // Metres per degree of latitude, for a point due north of the centre.
  final metresPerDegree = 6371000 * pi / 180;

  double northOf(double metres) => centreLatitude + metres / metresPerDegree;

  group('create', () {
    test('the default radius is 150 m', () {
      final area = PlaceArea.create(
        latitudeDegrees: centreLatitude,
        longitudeDegrees: centreLongitude,
      )!;
      expect(area.radiusMeters, PlaceArea.defaultRadiusMeters);
      expect(area.radiusMeters, 150);
    });

    test('accepts the smallest and the largest radius', () {
      expect(
        PlaceArea.create(
          latitudeDegrees: centreLatitude,
          longitudeDegrees: centreLongitude,
          radiusMeters: PlaceArea.minRadiusMeters,
        ),
        isNotNull,
      );
      expect(
        PlaceArea.create(
          latitudeDegrees: centreLatitude,
          longitudeDegrees: centreLongitude,
          radiusMeters: PlaceArea.maxRadiusMeters,
        ),
        isNotNull,
      );
    });

    test('refuses a radius outside 50 m to 2 km', () {
      expect(
        PlaceArea.create(
          latitudeDegrees: centreLatitude,
          longitudeDegrees: centreLongitude,
          radiusMeters: 49,
        ),
        isNull,
      );
      expect(
        PlaceArea.create(
          latitudeDegrees: centreLatitude,
          longitudeDegrees: centreLongitude,
          radiusMeters: 2001,
        ),
        isNull,
      );
    });

    test('refuses a point off the globe', () {
      expect(
        PlaceArea.create(
          latitudeDegrees: 91,
          longitudeDegrees: centreLongitude,
        ),
        isNull,
      );
      expect(
        PlaceArea.create(
          latitudeDegrees: centreLatitude,
          longitudeDegrees: 181,
        ),
        isNull,
      );
      expect(
        PlaceArea.create(
          latitudeDegrees: double.nan,
          longitudeDegrees: centreLongitude,
        ),
        isNull,
      );
    });
  });

  group('microdegrees', () {
    test('rounds rather than truncates', () {
      expect(PlaceArea.toMicrodegrees(12.3456789), 12345679);
      expect(PlaceArea.toMicrodegrees(-12.3456789), -12345679);
    });

    test('keeps a whole degree whole', () {
      final area = PlaceArea.create(
        latitudeDegrees: centreLatitude,
        longitudeDegrees: centreLongitude,
      )!;
      expect(area.latitudeMicrodegrees, 52000000);
      expect(area.longitudeMicrodegrees, 13000000);
    });
  });

  group('containsPoint', () {
    test('the centre is inside, a point near the edge is not', () {
      final area = PlaceArea.create(
        latitudeDegrees: centreLatitude,
        longitudeDegrees: centreLongitude,
        radiusMeters: 150,
      )!;
      expect(area.containsPoint(centreLatitude, centreLongitude), isTrue);
      expect(area.containsPoint(northOf(140), centreLongitude), isTrue);
      expect(area.containsPoint(northOf(160), centreLongitude), isFalse);
    });

    test('a point far away is outside', () {
      final area = PlaceArea.create(
        latitudeDegrees: centreLatitude,
        longitudeDegrees: centreLongitude,
      )!;
      expect(area.containsPoint(centreLatitude + 5, centreLongitude), isFalse);
    });
  });

  group('fromStored', () {
    test('clamps a stored radius that is out of range', () {
      expect(
        PlaceArea.fromStored(
          latitudeMicrodegrees: 52000000,
          longitudeMicrodegrees: 13000000,
          radiusMeters: 10,
        )!
        .radiusMeters,
        PlaceArea.minRadiusMeters,
      );
      expect(
        PlaceArea.fromStored(
          latitudeMicrodegrees: 52000000,
          longitudeMicrodegrees: 13000000,
          radiusMeters: 9000,
        )!
        .radiusMeters,
        PlaceArea.maxRadiusMeters,
      );
    });

    test('refuses a stored point off the globe', () {
      expect(
        PlaceArea.fromStored(
          latitudeMicrodegrees: 91000000,
          longitudeMicrodegrees: 13000000,
          radiusMeters: 150,
        ),
        isNull,
      );
    });
  });
}
