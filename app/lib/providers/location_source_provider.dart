/// Where Jeeves reads the location from, and how it turns an address into a
/// point (issue #55).
///
/// The web has neither: it never reads a location and it has no geocoder.
/// Everywhere else the platform does both.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/geolocator_location_source.dart';
import '../services/location_source.dart';

/// The location port. A journey overrides this with a recording fake.
final locationSourceProvider = Provider<LocationSource>((ref) {
  if (kIsWeb) return const WebLocationSource();
  return GeolocatorLocationSource();
});

/// The geocoder port. A journey overrides this with a fake that answers a
/// canned address.
final addressGeocoderProvider = Provider<AddressGeocoder>((ref) {
  if (kIsWeb) return const WebAddressGeocoder();
  return const GeocodingAddressGeocoder();
});
