/// The web side of the geofence port: there are no arrivals there (issue
/// #1092).
library;

import 'arrival_snapshot.dart';
import 'geofence_registrar.dart';

/// The web has no arrival notification.
const bool arrivalNotificationsSupported = false;

/// The registrar for this platform.
GeofenceRegistrar createGeofenceRegistrar() => const WebGeofenceRegistrar();

/// The registrar of a platform with no geofences: it watches nothing.
class WebGeofenceRegistrar implements GeofenceRegistrar {
  const WebGeofenceRegistrar();

  @override
  Future<Set<String>> registeredIds() async => const <String>{};

  @override
  Future<void> register(ArrivalPlace place) async {}

  @override
  Future<void> remove(String id) async {}
}
