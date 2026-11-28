/// Tells the OS which Places to watch (issue #1092).
///
/// The OS holds the geofences, not Jeeves, so the app can only ask what is
/// registered, register one and remove one. Everything else in the arrival
/// path goes through this small port, so a journey can see what the OS would
/// be watching without a phone.
library;

import 'package:flutter/foundation.dart' show debugPrint;

import 'arrival_snapshot.dart';
import 'location_source.dart';

// The platform's registrar and whether arrivals exist there, by conditional
// export: the web build never reaches the native geofence plugin.
export 'geofence_registrar_stub.dart'
    if (dart.library.io) 'geofence_registrar_io.dart'
    show arrivalNotificationsSupported, createGeofenceRegistrar;

/// The OS's list of Places to watch.
abstract class GeofenceRegistrar {
  /// The ids of the Places the OS is watching now.
  Future<Set<String>> registeredIds();

  /// Asks the OS to watch [place]: to tell Jeeves when the user comes into
  /// its area and when they leave it.
  Future<void> register(ArrivalPlace place);

  /// Asks the OS to stop watching the Place with [id].
  Future<void> remove(String id);
}

/// The prefix of a Place's geofence id, so Jeeves never mistakes another
/// geofence for one of its Places.
const String arrivalGeofenceIdPrefix = 'place:';

/// What the area of a Place is, in one string: when it changes, the OS's
/// geofence is the wrong shape and must be made again.
String arrivalAreaSignature(ArrivalPlace place) =>
    '${place.latitudeMicrodegrees},${place.longitudeMicrodegrees},'
    '${place.radiusMeters}';

/// Makes the OS watch exactly the Places of [snapshot].
///
/// [areas] is what Jeeves registered last, by Place id: the OS reports ids
/// only, so a Place whose area was edited is told apart by its signature.
/// Returns the areas now registered.
///
/// Without "all the time" the OS refuses to register anything, so nothing is
/// added then; a Place that is no longer wanted is still removed. A single
/// failure is logged and the Place tried again on the next run — it must not
/// stop the others.
Future<Map<String, String>> reconcileGeofences({
  required GeofenceRegistrar registrar,
  required ArrivalSnapshot snapshot,
  required Map<String, String> areas,
  required LocationPermission permission,
}) async {
  final kept = <String, String>{};
  final Set<String> registered;
  try {
    registered = await registrar.registeredIds();
  } on Object catch (error) {
    debugPrint('Arrival geofences could not be listed: $error');
    return areas;
  }

  final wanted = {for (final place in snapshot.places) place.id: place};

  for (final id in registered.where((id) => !wanted.containsKey(id))) {
    try {
      await registrar.remove(id);
    } on Object catch (error) {
      debugPrint('Arrival geofence $id could not be removed: $error');
      kept[id] = areas[id] ?? '';
    }
  }

  if (permission != LocationPermission.always) {
    if (wanted.isNotEmpty) {
      debugPrint('Arrival geofences skipped: location is not "all the time".');
    }
    // What stays registered is still what was registered before.
    return {
      for (final id in registered)
        if (wanted.containsKey(id) || kept.containsKey(id))
          id: areas[id] ?? '',
    };
  }

  for (final place in wanted.values) {
    final signature = arrivalAreaSignature(place);
    final isWatched = registered.contains(place.id);
    if (isWatched && areas[place.id] == signature) {
      kept[place.id] = signature;
      continue;
    }
    try {
      if (isWatched) await registrar.remove(place.id);
      await registrar.register(place);
      kept[place.id] = signature;
    } on Object catch (error) {
      // Includes the plugin's missing-permission error: the user may have
      // withdrawn "all the time" since the check above.
      debugPrint('Arrival geofence ${place.id} could not be registered: $error');
    }
  }
  return kept;
}
