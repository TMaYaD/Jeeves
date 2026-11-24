/// The real [LocationSource] and [AddressGeocoder]: the platform's own
/// location, through geolocator and geocoding (issue #55).
///
/// A read never asks for permission. The plugin's permission prompt is only
/// reached through [GeolocatorLocationSource.requestWhileUsing], which an
/// explicit tap by the user calls.
///
/// The web never reads a location: [WebLocationSource] answers "unknown" to
/// everything, and there is no geocoder there either.
library;

import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart' as geo;

import 'location_source.dart';

/// The platform's location, through geolocator.
class GeolocatorLocationSource implements LocationSource {
  GeolocatorLocationSource();

  @override
  bool get supportsPermissionPrompt => true;

  @override
  Future<LocationPermission> permission() async {
    try {
      return _map(await geo.Geolocator.checkPermission());
    } on Object {
      // A platform with no location plugin answers "not asked".
      return LocationPermission.notAsked;
    }
  }

  @override
  Future<LocationPermission> requestWhileUsing() async {
    try {
      return _map(await geo.Geolocator.requestPermission());
    } on Object {
      return LocationPermission.notAsked;
    }
  }

  @override
  Future<GeoPoint?> lastKnown() async {
    if (!await _mayRead()) return null;
    try {
      final position = await geo.Geolocator.getLastKnownPosition();
      if (position == null) return null;
      return _point(position);
    } on Object {
      // The OS may refuse a last-known position outright; that is "unknown",
      // not a failure the user needs to hear about.
      return null;
    }
  }

  @override
  Future<GeoPoint?> freshFix({required Duration timeout}) async {
    if (!await _mayRead()) return null;
    try {
      final position = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
          // geolocator's medium accuracy is Android's balanced power
          // accuracy: accurate enough to say "at the Place", cheap enough to
          // keep running while Jeeves is on screen.
          accuracy: geo.LocationAccuracy.medium,
        ),
      ).timeout(timeout);
      return _point(position);
    } on Object {
      // A fix that does not arrive in time, or one the OS refuses, is "no fix".
      return null;
    }
  }

  /// The positions while Jeeves is on screen.
  ///
  /// The stream opens lazily and **only when the OS allows a read**: a phone
  /// without the permission, or a platform with no location plugin, has
  /// nothing to listen to, and asking the plugin for one would only raise an
  /// error where there is no answer to give.
  @override
  Stream<GeoPoint> whileOpen() {
    return Stream<GeoPoint>.multi((controller) async {
      if (!await _mayRead()) return;
      final subscription = geo.Geolocator.getPositionStream(
        locationSettings: const geo.LocationSettings(
          // Medium accuracy is Android's balanced power accuracy.
          accuracy: geo.LocationAccuracy.medium,
          // The filter keeps a still user from waking the app every few metres.
          distanceFilter: 25,
        ),
      ).listen(
        (position) {
          if (!controller.isClosed) controller.add(_point(position));
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!controller.isClosed) controller.addError(error, stackTrace);
        },
      );
      controller.onCancel = subscription.cancel;
    });
  }

  /// Whether the OS allows a read at all. Without permission there is nothing
  /// to read, and asking would be a prompt the user did not ask for.
  Future<bool> _mayRead() async {
    final permission = await this.permission();
    return permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;
  }

  /// The plugin's own permission, as Jeeves's. Anything the plugin cannot
  /// make sense of reads as "not asked", which is the state in which asking is
  /// still allowed.
  static LocationPermission _map(geo.LocationPermission permission) {
    if (permission == geo.LocationPermission.denied) {
      return LocationPermission.denied;
    }
    if (permission == geo.LocationPermission.deniedForever) {
      return LocationPermission.deniedForever;
    }
    if (permission == geo.LocationPermission.whileInUse) {
      return LocationPermission.whileInUse;
    }
    if (permission == geo.LocationPermission.always) {
      return LocationPermission.always;
    }
    return LocationPermission.notAsked;
  }

  static GeoPoint _point(geo.Position position) => (
        latitudeDegrees: position.latitude,
        longitudeDegrees: position.longitude,
      );
}

/// The web's location: none. The web never reads where the user is.
class WebLocationSource implements LocationSource {
  const WebLocationSource();

  @override
  bool get supportsPermissionPrompt => false;

  @override
  Future<LocationPermission> permission() async =>
      LocationPermission.notAsked;

  @override
  Future<LocationPermission> requestWhileUsing() async =>
      LocationPermission.notAsked;

  @override
  Future<GeoPoint?> lastKnown() async => null;

  @override
  Future<GeoPoint?> freshFix({required Duration timeout}) async => null;

  @override
  Stream<GeoPoint> whileOpen() => const Stream<GeoPoint>.empty();
}

/// The platform geocoder: a typed address becomes a point.
///
/// The address leaves the phone — it goes to the platform's geocoder, which on
/// Android is Google's. That is the personal-data touch the pull request names.
class GeocodingAddressGeocoder implements AddressGeocoder {
  const GeocodingAddressGeocoder();

  @override
  Future<GeoPoint?> pointForAddress(String address) async {
    final trimmed = address.trim();
    if (trimmed.isEmpty) return null;
    try {
      final locations = await Geocoding().locationFromAddress(trimmed);
      if (locations.isEmpty) return null;
      final location = locations.first;
      return (
        latitudeDegrees: location.latitude,
        longitudeDegrees: location.longitude,
      );
    } on Object {
      // The geocoder knows some addresses and not others; not knowing one is
      // an ordinary answer, not a failure.
      return null;
    }
  }
}

/// The web's geocoder: none. The web has no address search.
class WebAddressGeocoder implements AddressGeocoder {
  const WebAddressGeocoder();

  @override
  Future<GeoPoint?> pointForAddress(String address) async => null;
}
