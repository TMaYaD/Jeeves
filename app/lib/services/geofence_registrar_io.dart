/// The Android side of the geofence port (issue #1092).
library;

import 'package:native_geofence/native_geofence.dart';

import 'arrival_background_entry_point.dart';
import 'arrival_snapshot.dart';
import 'geofence_registrar.dart';

/// Arrivals exist on a phone.
const bool arrivalNotificationsSupported = true;

/// The registrar for this platform.
GeofenceRegistrar createGeofenceRegistrar() => NativeGeofenceRegistrar();

/// The registrar that talks to Android's geofencing through `native_geofence`.
class NativeGeofenceRegistrar implements GeofenceRegistrar {
  NativeGeofenceRegistrar();

  Future<void>? _initialized;

  Future<NativeGeofenceManager> _manager() async {
    final manager = NativeGeofenceManager.instance;
    await (_initialized ??= manager.initialize());
    return manager;
  }

  @override
  Future<Set<String>> registeredIds() async {
    final ids = await (await _manager()).getRegisteredGeofenceIds();
    return {
      for (final id in ids)
        if (id.startsWith(arrivalGeofenceIdPrefix))
          id.substring(arrivalGeofenceIdPrefix.length),
    };
  }

  @override
  Future<void> register(ArrivalPlace place) async {
    await (await _manager()).createGeofence(
      Geofence(
        id: '$arrivalGeofenceIdPrefix${place.id}',
        location: Location(
          latitude: place.latitudeMicrodegrees / 1e6,
          longitude: place.longitudeMicrodegrees / 1e6,
        ),
        radiusMeters: place.radiusMeters.toDouble(),
        triggers: {GeofenceEvent.enter, GeofenceEvent.exit},
        iosSettings: const IosGeofenceSettings(initialTrigger: false),
        // No initial trigger: turning the switch on while standing in the
        // Place is not an arrival.
        androidSettings: const AndroidGeofenceSettings(
          initialTriggers: <GeofenceEvent>{},
        ),
      ),
      handleArrivalGeofenceEvent,
    );
  }

  @override
  Future<void> remove(String id) async {
    await (await _manager()).removeGeofenceById('$arrivalGeofenceIdPrefix$id');
  }
}
