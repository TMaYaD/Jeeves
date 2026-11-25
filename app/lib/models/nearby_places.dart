/// Grouping of Places that are near each other (issue #1090).
///
/// The rule: two Places are near each other when their points are close, and
/// Places that are near each other belong in one group. A group never holds
/// two Places that are further apart than a Place that sits in another group —
/// so a Place is never left behind because a nearer one was put elsewhere.
///
/// The grouping is a pure function of the points, worked out on the phone
/// with no outside service. It is reusable: a route over many Places (#60)
/// splits along the same groups.
library;

import 'place_area.dart';

/// The largest distance between any two Places in one group, in metres.
///
/// A few minutes' drive. One constant, so the number is easy to change.
const int nearbyGroupMaxSpreadMeters = 2000;

/// Splits [items] into groups of items whose points are near each other.
///
/// [areaOf] gives the point of an item; [compare] orders the items, so the
/// groups and their members come out in a fixed order and never shuffle
/// between rebuilds.
///
/// A group is kept whole when its widest spread — the largest distance
/// between two of its members — is at most [maxSpreadMeters] and at most the
/// distance to the nearest item outside it. The second half is what keeps a
/// nearer Place out of another group while two further ones share one: the
/// group is cut until it holds.
List<List<T>> groupNearby<T>(
  List<T> items, {
  required PlaceArea Function(T item) areaOf,
  required int Function(T a, T b) compare,
  int maxSpreadMeters = nearbyGroupMaxSpreadMeters,
}) {
  if (items.isEmpty) return [];
  final sorted = [...items]..sort(compare);
  if (sorted.length == 1) return [sorted];
  final areas = [for (final item in sorted) areaOf(item)];
  final distances = _distanceMatrix(areas);
  var links = _minimumSpanningTreeLinks(distances);
  while (true) {
    _Link? cut;
    for (final group in _componentsOf(sorted.length, links)) {
      if (group.length < 2) continue;
      final spreadMeters = _spreadMeters(group, distances);
      final closeEnough = spreadMeters <= maxSpreadMeters;
      final noNearerOutsider = spreadMeters <= _gapMeters(group, distances);
      if (closeEnough && noNearerOutsider) continue;
      final longest = _longestLinkIn(group, links);
      if (longest == null) continue;
      if (cut == null || _isLaterLink(longest, cut)) cut = longest;
    }
    if (cut == null) break;
    links.remove(cut);
  }
  return [
    for (final group in _componentsOf(sorted.length, links))
      [for (final index in group) sorted[index]],
  ];
}

/// The distance between every pair of points, in metres.
List<List<double>> _distanceMatrix(List<PlaceArea> areas) {
  final n = areas.length;
  final distances = List.generate(n, (_) => List<double>.filled(n, 0));
  for (var i = 0; i < n; i++) {
    for (var j = i + 1; j < n; j++) {
      final meters = areas[i].distanceMetersTo(areas[j]);
      distances[i][j] = meters;
      distances[j][i] = meters;
    }
  }
  return distances;
}

/// The links of the minimum spanning tree of the points (Prim's algorithm).
///
/// The shortest way to join every point; the groups are cut from it.
List<_Link> _minimumSpanningTreeLinks(List<List<double>> distances) {
  final n = distances.length;
  final inTree = List<bool>.filled(n, false);
  final links = <_Link>[];
  inTree[0] = true;
  for (var step = 1; step < n; step++) {
    _Link? best;
    for (var i = 0; i < n; i++) {
      if (!inTree[i]) continue;
      for (var j = 0; j < n; j++) {
        if (inTree[j]) continue;
        final candidate = _Link(i, j, distances[i][j]);
        if (best == null || _isEarlierLink(candidate, best)) best = candidate;
      }
    }
    if (best == null) break;
    links.add(best);
    inTree[best.first] = true;
    inTree[best.second] = true;
  }
  return links;
}

/// The groups the links join, each by the indices of its members.
///
/// The members of a group come out in order, and the groups come out by
/// their first member.
List<List<int>> _componentsOf(int n, List<_Link> links) {
  final parent = List<int>.generate(n, (i) => i);
  int find(int index) {
    while (parent[index] != index) {
      parent[index] = parent[parent[index]];
      index = parent[index];
    }
    return index;
  }

  for (final link in links) {
    final first = find(link.first);
    final second = find(link.second);
    if (first == second) continue;
    parent[first < second ? second : first] = first < second ? first : second;
  }

  final byRoot = <int, List<int>>{};
  for (var index = 0; index < n; index++) {
    byRoot.putIfAbsent(find(index), () => <int>[]).add(index);
  }
  final groups = byRoot.values.toList()
    ..sort((a, b) => a.first.compareTo(b.first));
  return groups;
}

/// The largest distance between two members of [group], in metres.
double _spreadMeters(List<int> group, List<List<double>> distances) {
  var spread = 0.0;
  for (var i = 0; i < group.length; i++) {
    for (var j = i + 1; j < group.length; j++) {
      final meters = distances[group[i]][group[j]];
      if (meters > spread) spread = meters;
    }
  }
  return spread;
}

/// The distance from the group to the nearest item outside it, in metres.
///
/// Infinite when nothing sits outside the group.
double _gapMeters(List<int> group, List<List<double>> distances) {
  final inside = group.toSet();
  var gap = double.infinity;
  for (final member in group) {
    for (var index = 0; index < distances.length; index++) {
      if (inside.contains(index)) continue;
      final meters = distances[member][index];
      if (meters < gap) gap = meters;
    }
  }
  return gap;
}

/// The longest link that sits inside [group], or null when it has none.
_Link? _longestLinkIn(List<int> group, List<_Link> links) {
  final inside = group.toSet();
  _Link? longest;
  for (final link in links) {
    if (!inside.contains(link.first) || !inside.contains(link.second)) continue;
    if (longest == null || _isLaterLink(link, longest)) longest = link;
  }
  return longest;
}

/// Whether [a] comes before [b]: the shorter link wins, and a tie goes to the
/// lower pair of indices.
bool _isEarlierLink(_Link a, _Link b) {
  if (a.meters != b.meters) return a.meters < b.meters;
  return _indexBefore(a, b);
}

/// Whether [a] comes after [b].
bool _isLaterLink(_Link a, _Link b) {
  if (a.meters != b.meters) return a.meters > b.meters;
  return _indexBefore(b, a);
}

bool _indexBefore(_Link a, _Link b) {
  if (a.first != b.first) return a.first < b.first;
  return a.second < b.second;
}

/// One link of the tree, between two points.
class _Link {
  _Link(int first, int second, this.meters)
      : first = first < second ? first : second,
        second = first < second ? second : first;

  /// The index of the lower of the two points.
  final int first;

  /// The index of the higher of the two points.
  final int second;

  /// The distance between the two points, in metres.
  final double meters;
}
