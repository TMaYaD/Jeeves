/// Errand routes (issue #60): how chosen stops are cut into routes and what
/// the map-app links look like.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/models/errand_route.dart';
import 'package:jeeves/models/place_area.dart';

ErrandStop _stop(String id, double latitude, double longitude) => ErrandStop(
      placeId: id,
      label: 'Name of $id',
      area: PlaceArea.create(
        latitudeDegrees: latitude,
        longitudeDegrees: longitude,
        radiusMeters: 150,
      )!,
    );

/// [count] stops about 11 m apart in a line, starting at [latitude].
List<ErrandStop> _cluster(String prefix, int count, double latitude) => [
      for (var i = 0; i < count; i++)
        _stop('$prefix$i', latitude + i * 0.0001, 4.8952),
    ];

/// No route has a spread wider than the distance from it to a stop that sits
/// on another route.
void _expectNearRuleHolds(List<List<ErrandStop>> routes, List<ErrandStop> all) {
  for (final route in routes) {
    final inRoute = _ids(route).toSet();
    final spread = _spreadMeters(route);
    for (final other in all) {
      if (inRoute.contains(other.placeId)) continue;
      for (final stop in route) {
        expect(spread,
            lessThanOrEqualTo(stop.area.distanceMetersTo(other.area)));
      }
    }
  }
}

List<String> _ids(List<ErrandStop> route) =>
    [for (final stop in route) stop.placeId];

void main() {
  group('errandRoutes', () {
    test('no stops make no route', () {
      expect(errandRoutes([]), isEmpty);
      expect(errandRoutes([[], []]), isEmpty);
    });

    test('ten stops or fewer make one route, in page order', () {
      final first = _cluster('a', 3, 52.37);
      final second = _cluster('b', 7, 52.0);
      final routes = errandRoutes([first, second]);
      expect(routes, hasLength(1));
      expect(_ids(routes.single), [..._ids(first), ..._ids(second)]);
    });

    test('more than ten stops make one route per group', () {
      final near = _cluster('a', 6, 52.37);
      final far = _cluster('b', 8, 52.0);
      final routes = errandRoutes([near, far]);
      expect([for (final route in routes) _ids(route)],
          [_ids(near), _ids(far)]);
    });

    test('a group of fourteen stops is cut into routes of ten or fewer', () {
      // Two blobs of seven stops, about 800 m apart: one group, since they
      // are near each other, but more stops than a route holds.
      final west = _cluster('w', 7, 52.37);
      final east = _cluster('e', 7, 52.3772);
      final routes = errandRoutes([
        [...west, ...east],
      ]);
      expect([for (final route in routes) _ids(route)],
          [_ids(west), _ids(east)]);
      _expectNearRuleHolds(routes, [...west, ...east]);
    });

    test('a cut that has nothing sensible to keep falls to single stops', () {
      // Fourteen stops in an even line: every stop is as close to the next
      // as to anything, so no route may join two and leave a neighbour out.
      final line = _cluster('a', 14, 52.37);
      final routes = errandRoutes([line]);
      for (final route in routes) {
        expect(route.length, lessThanOrEqualTo(googleMapsMaxStopsPerRoute));
      }
      expect(
        [for (final route in routes) ..._ids(route)]..sort(),
        (_ids(line)..sort()),
      );
      _expectNearRuleHolds(routes, line);
    });

    test('a different group is never joined into a cut route', () {
      final cluster = _cluster('a', 11, 52.37);
      final far = _cluster('b', 3, 52.0);
      final routes = errandRoutes([cluster, far]);
      for (final route in routes) {
        final prefixes = {for (final stop in route) stop.placeId[0]};
        expect(prefixes, hasLength(1));
      }
      expect(routes.fold<int>(0, (sum, route) => sum + route.length), 14);
    });
  });

  group('googleMapsRouteUri', () {
    test('the last stop is the destination, the others are waypoints', () {
      final uri = googleMapsRouteUri([
        _stop('a', 52.3702, 4.8952),
        _stop('b', 52.0800, 4.3),
        _stop('c', -33.8688, 151.2093),
      ]);
      expect(
        uri.toString(),
        'https://www.google.com/maps/dir/?api=1'
        '&destination=-33.868800%2C151.209300'
        '&waypoints=52.370200%2C4.895200%7C52.080000%2C4.300000'
        '&travelmode=driving',
      );
    });

    test('there is no origin, and a lone stop has no waypoints', () {
      final uri = googleMapsRouteUri([_stop('a', 52.3702, 4.8952)]);
      expect(uri.queryParameters.containsKey('origin'), isFalse);
      expect(uri.queryParameters.containsKey('waypoints'), isFalse);
      expect(uri.queryParameters['destination'], '52.370200,4.895200');
    });

    test('names of Places are never in the link', () {
      final uri = googleMapsRouteUri([
        _stop('a', 52.3702, 4.8952),
        _stop('b', 52.0800, 4.3),
      ]);
      expect(uri.toString(), isNot(contains('Name')));
    });

    test('a full route of ten stops stays well inside the URL limit', () {
      final uri = googleMapsRouteUri(_cluster('a', 10, -52.37));
      expect(uri.toString().length, lessThan(2048));
    });
  });

  group('wazeUri', () {
    test('goes to one point and starts navigating', () {
      expect(
        wazeUri(_stop('a', 52.3702, -4.8952)).toString(),
        'https://waze.com/ul?ll=52.370200%2C-4.895200&navigate=yes',
      );
    });
  });
}

double _spreadMeters(List<ErrandStop> route) {
  var spread = 0.0;
  for (final a in route) {
    for (final b in route) {
      final meters = a.area.distanceMetersTo(b.area);
      if (meters > spread) spread = meters;
    }
  }
  return spread;
}
