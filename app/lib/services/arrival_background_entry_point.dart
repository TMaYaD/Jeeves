/// The entry point the OS wakes when a Place's geofence fires while Jeeves is
/// closed (issue #1092).
///
/// It must be a top-level function, kept by the compiler, because the plugin
/// stores a handle to it and starts it in a headless engine. It only forwards:
/// what to do about an arrival lives elsewhere, where a test can reach it.
library;

import 'package:native_geofence/native_geofence.dart';

import 'arrival_notifications.dart';
import 'arrival_snapshot.dart';

/// Called by the OS in a headless engine on a geofence event.
@pragma('vm:entry-point')
Future<void> handleArrivalGeofenceEvent(GeofenceCallbackParams params) async {
  final isEnter = params.event == GeofenceEvent.enter;
  if (!isEnter && params.event != GeofenceEvent.exit) return;
  final files = await ArrivalFiles.inApplicationSupport();
  for (final geofence in params.geofences) {
    await handleArrivalEvent(
      geofenceId: geofence.id,
      isEnter: isEnter,
      nowUtc: DateTime.now().toUtc(),
      files: files,
      sink: LocalArrivalNotificationSink(),
    );
  }
}
