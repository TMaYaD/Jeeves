/// PlaceArea — the area of a Place (CONTEXT.md § Context).
///
/// A Place is a point plus an area: the point is where the Place is, the area
/// is how far the user is still "at" it. The point travels as integer
/// microdegrees (degrees × 1 000 000), because no float goes on the wire.
library;

import 'dart:math';

class PlaceArea {
  /// The radius a new Place gets.
  static const int defaultRadiusMeters = 150;

  /// The smallest radius a Place may have.
  static const int minRadiusMeters = 50;

  /// The largest radius a Place may have.
  static const int maxRadiusMeters = 2000;

  /// Degrees × 1 000 000: the unit coordinates travel in.
  static const int _microdegreesPerDegree = 1000000;

  /// The mean radius of the earth, for the distance between two points.
  static const double _earthRadiusMeters = 6371000;

  /// The latitude of the Place's point, in microdegrees.
  final int latitudeMicrodegrees;

  /// The longitude of the Place's point, in microdegrees.
  final int longitudeMicrodegrees;

  /// How far from that point the user still counts as being at the Place.
  final int radiusMeters;

  const PlaceArea._({
    required this.latitudeMicrodegrees,
    required this.longitudeMicrodegrees,
    required this.radiusMeters,
  });

  /// Degrees to microdegrees. Rounds, never truncates: a truncated degree
  /// loses up to 0.1 m of the point.
  ///
  /// A degree value so large that scaling it overflows is not a point at all;
  /// [create] refuses it before it reaches this rounding.
  static int toMicrodegrees(double degrees) =>
      (degrees * _microdegreesPerDegree).round();

  /// Whether scaling [degrees] to microdegrees overflows to infinity.
  static bool _overflowsWhenScaled(double degrees) =>
      (degrees * _microdegreesPerDegree).isInfinite;

  /// Builds a Place's area, or returns null when the value is invalid: a
  /// point off the globe, or a radius outside [minRadiusMeters] and
  /// [maxRadiusMeters]. A null [radiusMeters] means [defaultRadiusMeters].
  static PlaceArea? create({
    required double latitudeDegrees,
    required double longitudeDegrees,
    int? radiusMeters,
  }) {
    if (!latitudeDegrees.isFinite || !longitudeDegrees.isFinite) return null;
    // A huge but finite degree value overflows when it is scaled, and
    // rounding an infinite value throws. Such a point is far off the globe
    // and the range checks below refuse it anyway, so refuse it before it
    // is rounded.
    if (_overflowsWhenScaled(latitudeDegrees) ||
        _overflowsWhenScaled(longitudeDegrees)) {
      return null;
    }
    final latitude = toMicrodegrees(latitudeDegrees);
    final longitude = toMicrodegrees(longitudeDegrees);
    if (latitude < -90 * _microdegreesPerDegree ||
        latitude > 90 * _microdegreesPerDegree) {
      return null;
    }
    if (longitude < -180 * _microdegreesPerDegree ||
        longitude > 180 * _microdegreesPerDegree) {
      return null;
    }
    final radius = radiusMeters ?? defaultRadiusMeters;
    if (radius < minRadiusMeters || radius > maxRadiusMeters) return null;
    return PlaceArea._(
      latitudeMicrodegrees: latitude,
      longitudeMicrodegrees: longitude,
      radiusMeters: radius,
    );
  }

  /// Reads a stored area. A stored radius outside the accepted range is
  /// clamped into it — a tolerant reader, because a radius the app cannot
  /// make sense of should still leave the Place usable. A stored point off the
  /// globe is refused: there is nothing to clamp it to.
  static PlaceArea? fromStored({
    required int latitudeMicrodegrees,
    required int longitudeMicrodegrees,
    required int radiusMeters,
  }) {
    if (latitudeMicrodegrees < -90 * _microdegreesPerDegree ||
        latitudeMicrodegrees > 90 * _microdegreesPerDegree) {
      return null;
    }
    if (longitudeMicrodegrees < -180 * _microdegreesPerDegree ||
        longitudeMicrodegrees > 180 * _microdegreesPerDegree) {
      return null;
    }
    return PlaceArea._(
      latitudeMicrodegrees: latitudeMicrodegrees,
      longitudeMicrodegrees: longitudeMicrodegrees,
      radiusMeters: radiusMeters.clamp(minRadiusMeters, maxRadiusMeters),
    );
  }

  /// Whether the point ([latitudeDegrees], [longitudeDegrees]) is inside this
  /// Place's area.
  bool containsPoint(double latitudeDegrees, double longitudeDegrees) {
    if (!latitudeDegrees.isFinite || !longitudeDegrees.isFinite) return false;
    final distance = _distanceMeters(
      latitudeMicrodegrees / _microdegreesPerDegree,
      longitudeMicrodegrees / _microdegreesPerDegree,
      latitudeDegrees,
      longitudeDegrees,
    );
    return distance <= radiusMeters;
  }

  /// The distance between two points, in metres (haversine).
  static double _distanceMeters(
    double latitude1,
    double longitude1,
    double latitude2,
    double longitude2,
  ) {
    const toRadians = pi / 180;
    final deltaLatitude = (latitude2 - latitude1) * toRadians;
    final deltaLongitude = (longitude2 - longitude1) * toRadians;
    final a = sin(deltaLatitude / 2) * sin(deltaLatitude / 2) +
        cos(latitude1 * toRadians) *
            cos(latitude2 * toRadians) *
            sin(deltaLongitude / 2) *
            sin(deltaLongitude / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return _earthRadiusMeters * c;
  }

  @override
  bool operator ==(Object other) =>
      other is PlaceArea &&
      other.latitudeMicrodegrees == latitudeMicrodegrees &&
      other.longitudeMicrodegrees == longitudeMicrodegrees &&
      other.radiusMeters == radiusMeters;

  @override
  int get hashCode =>
      Object.hash(latitudeMicrodegrees, longitudeMicrodegrees, radiusMeters);

  @override
  String toString() => 'PlaceArea(lat: $latitudeMicrodegrees, '
      'lon: $longitudeMicrodegrees, radius: ${radiusMeters}m)';
}
