/// The entry point the OS wakes when a Place's geofence fires while Jeeves is
/// closed (issue #1092).
///
/// It must be a top-level function, kept by the compiler, because the plugin
/// stores a handle to it and starts it in a headless engine. It only forwards:
/// what to do about an arrival lives elsewhere, where a test can reach it.
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:native_geofence/native_geofence.dart';

/// Called by the OS in a headless engine on a geofence event.
@pragma('vm:entry-point')
Future<void> handleArrivalGeofenceEvent(GeofenceCallbackParams params) async {
  // The arrival notification is wired in a later step.
  debugPrint('Arrival geofence event ${params.event.name}');
}
