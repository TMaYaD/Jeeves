/// Errand routes: the stops the user chose, cut into routes a map app takes
/// (issue #60).
///
/// Jeeves does not plan routes. It hands the chosen Places to Google Maps or
/// Waze, in the order the place page shows them, and the app does the
/// routing. The only thing Jeeves decides is how to cut a long list of stops
/// into routes the app can take without dropping one.
library;

import 'nearby_places.dart';
import 'place_area.dart';

/// How many stops one Google Maps route holds.
///
/// Google's Directions URL takes a destination and at most nine waypoints
/// outside mobile browsers, so ten stops:
/// https://developers.google.com/maps/documentation/urls/get-started
/// (a mobile browser takes only three waypoints; Jeeves opens the Maps app).
const int googleMapsMaxStopsPerRoute = 10;

/// One stop of an errand: a Place that has at least one chosen Outcome.
class ErrandStop {
  const ErrandStop({
    required this.placeId,
    required this.label,
    required this.area,
  });

  /// The Place of the stop. Two chosen Outcomes at one Place are one stop.
  final String placeId;

  /// The name the user knows the Place by. Never sent to a map app.
  final String label;

  /// Where the stop is.
  final PlaceArea area;
}

/// Cuts [stopsByGroup] into routes of at most [maxStopsPerRoute] stops.
///
/// [stopsByGroup] holds the chosen stops of each group of nearby Places, in
/// the order the place page draws them.
///
/// * When every stop fits in one route, that is the one route.
/// * Otherwise there is one route per group. A group with more stops than a
///   route holds is cut again along the same nearby-places rule, so a route
///   never joins stops that are far apart while closer stops go to another
///   route.
///
/// No stop is dropped and none is listed twice. Stops keep the page order
/// inside a route, and the routes keep the page order too.
List<List<ErrandStop>> errandRoutes(
  List<List<ErrandStop>> stopsByGroup, {
  int maxStopsPerRoute = googleMapsMaxStopsPerRoute,
}) {
  final groups = [
    for (final group in stopsByGroup)
      if (group.isNotEmpty) group,
  ];
  final stopCount = groups.fold<int>(0, (sum, group) => sum + group.length);
  if (stopCount == 0) return [];
  if (stopCount <= maxStopsPerRoute) {
    return [
      [for (final group in groups) ...group],
    ];
  }
  final routes = <List<ErrandStop>>[];
  for (final group in groups) {
    if (group.length <= maxStopsPerRoute) {
      routes.add(group);
      continue;
    }
    final pageOrder = {
      for (final (index, stop) in group.indexed) stop: index,
    };
    routes.addAll(groupNearby<ErrandStop>(
      group,
      areaOf: (stop) => stop.area,
      compare: (a, b) => pageOrder[a]!.compareTo(pageOrder[b]!),
      maxMembers: maxStopsPerRoute,
    ));
  }
  return routes;
}

/// The Google Maps link for [route]: the last stop is the destination and
/// the others are waypoints, in order.
///
/// There is no origin, so Maps starts from the device's own location, which
/// never leaves the phone. The travel mode is set because Maps may otherwise
/// choose transit, which takes no waypoints. Only coordinates are sent: the
/// names of the Places stay in Jeeves.
Uri googleMapsRouteUri(List<ErrandStop> route) {
  assert(route.isNotEmpty, 'a route has at least one stop');
  final waypoints = route.sublist(0, route.length - 1);
  return Uri.https('www.google.com', '/maps/dir/', {
    'api': '1',
    'destination': _pointOf(route.last),
    if (waypoints.isNotEmpty) 'waypoints': waypoints.map(_pointOf).join('|'),
    'travelmode': 'driving',
  });
}

/// The Waze link for [stop]. Waze takes one destination, so a route of many
/// stops goes one stop at a time.
Uri wazeUri(ErrandStop stop) => Uri.https('waze.com', '/ul', {
      'll': _pointOf(stop),
      'navigate': 'yes',
    });

/// "lat,lng" in degrees with six decimals, from the exact microdegrees.
String _pointOf(ErrandStop stop) =>
    '${_degrees(stop.area.latitudeMicrodegrees)},'
    '${_degrees(stop.area.longitudeMicrodegrees)}';

String _degrees(int microdegrees) {
  final sign = microdegrees < 0 ? '-' : '';
  final magnitude = microdegrees.abs();
  final whole = magnitude ~/ 1000000;
  final fraction = (magnitude % 1000000).toString().padLeft(6, '0');
  return '$sign$whole.$fraction';
}
