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

    test('refuses a point whose scaling overflows', () {
      // A huge but finite degree value: scaling it to microdegrees overflows
      // to infinity, and rounding an infinite value throws. Such a point is
      // far off the globe, so it is refused like any other — and refusing it
      // means returning null, not throwing.
      expect(
        PlaceArea.create(
          latitudeDegrees: 1e308,
          longitudeDegrees: centreLongitude,
        ),
        isNull,
      );
      expect(
        PlaceArea.create(
          latitudeDegrees: centreLatitude,
          longitudeDegrees: 1e308,
        ),
        isNull,
      );
    });

    test('accepts a point just past a pole that rounds into range', () {
      // 90.0000001° rounds to 90.000000°, which is on the globe: the
      // rounding is what decides, and it must not turn into a refusal.
      final area = PlaceArea.create(
        latitudeDegrees: 90.0000001,
        longitudeDegrees: centreLongitude,
      );
      expect(area, isNotNull);
      expect(area!.latitudeMicrodegrees, 90000000);
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

  group('isPointOnGlobe', () {
    test('accepts a point on the globe', () {
      expect(
        PlaceArea.isPointOnGlobe(
          latitudeMicrodegrees: 52000000,
          longitudeMicrodegrees: 13000000,
        ),
        isTrue,
      );
      expect(
        PlaceArea.isPointOnGlobe(
          latitudeMicrodegrees: 90000000,
          longitudeMicrodegrees: 180000000,
        ),
        isTrue,
      );
      expect(
        PlaceArea.isPointOnGlobe(
          latitudeMicrodegrees: -90000000,
          longitudeMicrodegrees: -180000000,
        ),
        isTrue,
      );
    });

    test('refuses a point off the globe', () {
      expect(
        PlaceArea.isPointOnGlobe(
          latitudeMicrodegrees: 91000000,
          longitudeMicrodegrees: 13000000,
        ),
        isFalse,
      );
      expect(
        PlaceArea.isPointOnGlobe(
          latitudeMicrodegrees: 52000000,
          longitudeMicrodegrees: 181000000,
        ),
        isFalse,
      );
    });
  });
}
