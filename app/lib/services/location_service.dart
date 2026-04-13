// Location service — geofencing and location tagging.
//
// Uses geolocator for position fixes and constructs geofences locally.
// Geofence evaluation for reminders runs in the backend (or via platform
// channels on mobile for background delivery).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

class LocationService {
  LocationService._();

  static final LocationService instance = LocationService._();

  Future<bool> requestPermissions() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  Future<Position?> getCurrentPosition() async {
    final hasPermission = await requestPermissions();
    if (!hasPermission) return null;
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
      ),
    );
  }

  Stream<Position> positionStream() {
    return Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 50, // metres
      ),
    );
  }
}

final locationServiceProvider = Provider<LocationService>((ref) {
  return LocationService.instance;
});
