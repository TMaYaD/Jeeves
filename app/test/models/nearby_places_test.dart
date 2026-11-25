/// The grouping of Places that are near each other (issue #1090).
///
/// Two Places are near each other when their points are close. The groups
/// never hold two Places that are further apart than a Place in another group.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/models/nearby_places.dart';
import 'package:jeeves/models/place_area.dart';

/// A point near Amsterdam: 0.0009° of latitude is about 100 m.
PlaceArea _at(double latitudeDegrees, double longitudeDegrees) => PlaceArea.create(
      latitudeDegrees: latitudeDegrees,
      longitudeDegrees: longitudeDegrees,
      radiusMeters: 150,
    )!;

const _home = (latitude: 52.3702, longitude: 4.8952);

/// A point about 50 km away — nowhere near Home.
const _far = (latitude: 52.0800, longitude: 4.3000);

/// The groups of [items], with the points taken from [areas].
List<List<int>> _groupIndexes(
  List<int> items, {
  required Map<int, PlaceArea> areas,
  required int Function(int a, int b) compare,
  int maxSpreadMeters = nearbyGroupMaxSpreadMeters,
}) =>
    [
      for (final group in groupNearby<int>(
        items,
        areaOf: (item) => areas[item]!,
        compare: compare,
        maxSpreadMeters: maxSpreadMeters,
      ))
        group,
    ];

void main() {
  group('groupNearby', () {
    test('no items make no groups', () {
      expect(groupNearby<int>([], areaOf: (_) => _at(0, 0), compare: (a, b) => a - b), isEmpty);
    });

    test('one item makes one group of one', () {
      final groups = groupNearby<int>(
        [7],
        areaOf: (_) => _at(_home.latitude, _home.longitude),
        compare: (a, b) => a - b,
      );
      expect(groups, [
        [7]
      ]);
    });

    test('two Places 300 m apart are one group, a far one another', () {
      final areas = {
        1: _at(52.3702, 4.8952),
        2: _at(52.3729, 4.8952), // about 300 m north
        3: _at(_far.latitude, _far.longitude),
      };
      final groups = _groupIndexes([1, 2, 3], areas: areas, compare: (a, b) => a - b);
      expect(groups, [
        [1, 2],
        [3],
      ]);
    });

    test('a chain longer than the limit is cut', () {
      // A–B 1 km, B–C 1 km, A–C 2 km.
      final areas = {
        1: _at(52.3700, 4.8952),
        2: _at(52.3790, 4.8952),
        3: _at(52.3880, 4.8952),
      };
      final groups = _groupIndexes(
        [1, 2, 3],
        areas: areas,
        compare: (a, b) => a - b,
        maxSpreadMeters: 1500,
      );
      expect(groups, hasLength(2));
      // The link between B and C is the one cut: A and B stay together, and
      // C is on its own.
      expect(groups, [
        [1, 2],
        [3],
      ]);
      // The cut leaves no group holding two Places further apart than a
      // Place in another group.
      for (final group in groups) {
        for (final a in group) {
          for (final b in group) {
            for (final other in groups.where((g) => !g.contains(a))) {
              for (final c in other) {
                expect(
                  areas[a]!.distanceMetersTo(areas[b]!),
                  lessThanOrEqualTo(areas[a]!.distanceMetersTo(areas[c]!)),
                );
              }
            }
          }
        }
      }
    });

    test('two Places at the same point are one group', () {
      final areas = {
        1: _at(52.3702, 4.8952),
        2: _at(52.3702, 4.8952),
      };
      expect(
        _groupIndexes([1, 2], areas: areas, compare: (a, b) => a - b),
        [
          [1, 2]
        ],
      );
    });

    test('everything within 500 m is one group', () {
      final areas = {
        1: _at(52.3702, 4.8952),
        2: _at(52.3729, 4.8952), // about 300 m north
        3: _at(52.3746, 4.8952), // about 490 m north
      };
      expect(
        _groupIndexes([1, 2, 3], areas: areas, compare: (a, b) => a - b),
        [
          [1, 2, 3]
        ],
      );
    });

    test('two Places on opposite sides of the globe are never one group', () {
      final areas = {
        1: _at(82, 0),
        2: _at(-82, 180),
      };
      expect(
        _groupIndexes([1, 2], areas: areas, compare: (a, b) => a - b),
        [
          [1],
          [2]
        ],
      );
    });

    test('the groups and their members come out in the order given', () {
      // The far Place comes first by the order given, and stays first.
      final areas = {
        1: _at(_far.latitude, _far.longitude),
        2: _at(52.3702, 4.8952),
        3: _at(52.3729, 4.8952),
      };
      expect(
        _groupIndexes([1, 2, 3], areas: areas, compare: (a, b) => a - b),
        [
          [1],
          [2, 3],
        ],
      );
    });
  });

  group('the rule holds', () {
    test('for two hundred seeded layouts, no group holds a further pair '
        'than a Place in another group', () {
      final random = Random(20261125);
      for (var round = 0; round < 200; round++) {
        final count = 2 + random.nextInt(24);
        final areas = <int, PlaceArea>{};
        for (var index = 0; index < count; index++) {
          areas[index] = _at(
            52.3702 + (random.nextDouble() - 0.5) * 0.18,
            4.8952 + (random.nextDouble() - 0.5) * 0.27,
          );
        }
        final groups = _groupIndexes(
          List.generate(count, (index) => index),
          areas: areas,
          compare: (a, b) => a - b,
        );
        // Every group stays within the limit.
        for (final group in groups) {
          for (final a in group) {
            for (final b in group) {
              if (a == b) continue;
              expect(
                areas[a]!.distanceMetersTo(areas[b]!),
                lessThanOrEqualTo(nearbyGroupMaxSpreadMeters.toDouble()),
                reason: 'round $round: $a and $b are too far apart',
              );
            }
          }
        }
        // And no group holds a pair further apart than a Place elsewhere.
        for (final group in groups) {
          for (final a in group) {
            for (final b in group) {
              for (final other in groups.where((g) => !g.contains(a))) {
                for (final c in other) {
                  expect(
                    areas[a]!.distanceMetersTo(areas[b]!),
                    lessThanOrEqualTo(areas[a]!.distanceMetersTo(areas[c]!)),
                    reason: 'round $round: $a and $b are further apart than '
                        '$c, which is in another group',
                  );
                }
              }
            }
          }
        }
      }
    });
  });

  group('distanceMetersTo', () {
    test('a degree of latitude is about 111.2 km', () {
      final here = _at(52.3702, 4.8952);
      final there = _at(53.3702, 4.8952);
      final meters = here.distanceMetersTo(there);
      expect(meters, closeTo(111194.9, 111194.9 * 0.005));
    });

    test('the same point is no distance at all', () {
      final here = _at(52.3702, 4.8952);
      expect(here.distanceMetersTo(here), 0);
    });

    test('two points on opposite sides of the globe are a finite distance '
        'apart', () {
      // Half the way round the earth, whatever the latitude.
      for (var latitude = -90; latitude <= 90; latitude++) {
        final here = _at(latitude.toDouble(), 0);
        final there = _at((-latitude).toDouble(), 180);
        final meters = here.distanceMetersTo(there);
        expect(meters.isFinite, isTrue, reason: 'at latitude $latitude');
        expect(meters, closeTo(20015087, 20015087 * 0.001),
            reason: 'at latitude $latitude');
      }
    });
  });
}
