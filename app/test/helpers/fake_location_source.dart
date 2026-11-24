/// The recording stand-ins for the OS's location (issue #55).
///
/// [FakeLocationSource] answers what the test says and remembers every call,
/// so a journey can prove that Jeeves reads the location only while it is on
/// screen, that a fresh fix falls back to the last known position, and that
/// the permission is asked once and only on the user's ask.
///
/// [FakeAddressGeocoder] stands in for the platform geocoder, which is what
/// turns a typed address into a point.
library;

import 'dart:async';

import 'package:jeeves/providers/current_location_provider.dart';
import 'package:jeeves/services/location_source.dart';

/// The OS's location, stood in for.
class FakeLocationSource implements LocationSource {
  FakeLocationSource();

  /// What `permission()` answers.
  LocationPermission permissionState = LocationPermission.notAsked;

  /// What `requestWhileUsing()` answers.
  LocationPermission grantedPermission = LocationPermission.whileInUse;

  /// The point a fresh fix returns. Null stands for a fix that does not
  /// arrive.
  GeoPoint? freshPoint;

  /// The point the OS's last known position returns. Null stands for a phone
  /// that has never had a fix.
  GeoPoint? lastKnownPoint;

  /// Whether this platform has a permission prompt at all. The web has none.
  bool promptSupported = true;

  /// Every call the fake received, in order.
  final calls = <String>[];

  /// How many times Jeeves asked the OS for permission.
  int permissionRequests = 0;

  final StreamController<GeoPoint> _positions =
      StreamController<GeoPoint>.broadcast();

  @override
  bool get supportsPermissionPrompt => promptSupported;

  @override
  Future<LocationPermission> permission() async {
    calls.add('permission');
    return permissionState;
  }

  @override
  Future<LocationPermission> requestWhileUsing() async {
    calls.add('requestWhileUsing');
    permissionRequests++;
    permissionState = grantedPermission;
    return grantedPermission;
  }

  @override
  Future<GeoPoint?> lastKnown() async {
    calls.add('lastKnown');
    return lastKnownPoint;
  }

  @override
  Future<GeoPoint?> freshFix({required Duration timeout}) async {
    calls.add('freshFix');
    return freshPoint;
  }

  @override
  Stream<GeoPoint> whileOpen() {
    calls.add('whileOpen');
    return _positions.stream;
  }

  /// Moves the user to [point] while Jeeves is on screen.
  void moveTo(GeoPoint point) => _positions.add(point);

  /// How many times the fake was asked for a read of any kind.
  int get readCalls =>
      calls.where((call) => call == 'freshFix' || call == 'lastKnown').length;

  Future<void> dispose() => _positions.close();
}

/// The platform geocoder, stood in for.
class FakeAddressGeocoder implements AddressGeocoder {
  FakeAddressGeocoder({Map<String, GeoPoint>? points})
      : points = points ?? const {};

  /// The point for each address, keyed by the trimmed, lower-cased address.
  final Map<String, GeoPoint> points;

  /// Every address the geocoder was asked about, in order.
  final calls = <String>[];

  @override
  Future<GeoPoint?> pointForAddress(String address) async {
    calls.add(address);
    return points[address.trim().toLowerCase()];
  }
}

/// A location that never moves: the stand-in for a phone that has already
/// answered, and for a phone that never will.
class FixedLocationNotifier extends CurrentLocationNotifier {
  FixedLocationNotifier(this.fixedLocation);

  final CurrentLocation fixedLocation;

  @override
  CurrentLocation build() => fixedLocation;
}
