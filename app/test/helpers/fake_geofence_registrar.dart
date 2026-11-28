/// The recording stand-in for the OS's geofences (issue #1092).
///
/// It holds what the OS would be watching and records every call, so a
/// journey can see which Places Jeeves asked the OS to watch, and with which
/// area.
library;

import 'package:jeeves/services/arrival_snapshot.dart';
import 'package:jeeves/services/geofence_registrar.dart';

/// The OS's geofences, stood in for.
class FakeGeofenceRegistrar implements GeofenceRegistrar {
  /// The Places the "OS" is watching, by Place id.
  final Map<String, ArrivalPlace> watched = {};

  /// Every `register` call, in order.
  final registrations = <ArrivalPlace>[];

  /// Every `remove` call, in order, by Place id.
  final removals = <String>[];

  /// When set, `register` throws it: a phone that refuses the geofence.
  Object? registerError;

  @override
  Future<Set<String>> registeredIds() async => watched.keys.toSet();

  @override
  Future<void> register(ArrivalPlace place) async {
    final error = registerError;
    if (error != null) throw error;
    registrations.add(place);
    watched[place.id] = place;
  }

  @override
  Future<void> remove(String id) async {
    removals.add(id);
    watched.remove(id);
  }
}
