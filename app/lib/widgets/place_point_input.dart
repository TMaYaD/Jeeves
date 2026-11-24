/// The point input of a Place: where on the globe it is (issue #55).
///
/// Three ways to set a point, shared by the place editor and the pin sheet:
///
/// * "Use where I am" — the phone's own location. The user tapped it, so it
///   may ask for permission.
/// * an address — looked up by the platform geocoder, which on Android sends
///   the typed address to Google.
/// * a "latitude, longitude" pair — on every platform, for a point the user
///   has from elsewhere.
///
/// The chosen point is shown as text, so the user can see what they set.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/place_area.dart';
import '../providers/current_location_provider.dart';
import '../providers/location_source_provider.dart';
import '../services/location_source.dart';

/// The point input of a Place.
class PlacePointInput extends ConsumerStatefulWidget {
  const PlacePointInput({
    super.key,
    this.initialPoint,
    required this.onChanged,
  });

  /// The point the Place starts with, or null for a new one.
  final GeoPoint? initialPoint;

  /// Called with the chosen point, and with null when the user clears it.
  final ValueChanged<GeoPoint?> onChanged;

  @override
  ConsumerState<PlacePointInput> createState() => _PlacePointInputState();
}

class _PlacePointInputState extends ConsumerState<PlacePointInput>
    with WidgetsBindingObserver {
  final TextEditingController _coordinates = TextEditingController();
  final TextEditingController _address = TextEditingController();

  GeoPoint? _point;
  String? _message;

  /// Counts the point requests, so that a result which lands after the user
  /// has chosen something else is not applied.
  ///
  /// An address lookup and a location fix both take time. A result that
  /// arrives after the user has typed a coordinate of their own must not
  /// overwrite that coordinate: the newer, explicit choice wins.
  int _pointRequest = 0;

  /// The app's lifecycle state, as this widget last heard it.
  ///
  /// Null means nothing has been said yet, which is on screen: the widget has
  /// only just been built.
  AppLifecycleState? _lifecycleState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _point = widget.initialPoint;
    if (_point != null) _coordinates.text = _formatPoint(_point!);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _coordinates.dispose();
    _address.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
  }

  /// The point as "latitude, longitude", to five decimals — enough to name a
  /// place, short enough to read.
  static String _formatPoint(GeoPoint point) =>
      '${point.latitudeDegrees.toStringAsFixed(5)}, '
      '${point.longitudeDegrees.toStringAsFixed(5)}';

  /// Takes a point that came from somewhere else — the phone's own location,
  /// or an address the geocoder knew — and shows it in the field.
  void _takePoint(GeoPoint point) {
    setState(() {
      _point = point;
      _message = null;
      _coordinates.text = _formatPoint(point);
    });
    widget.onChanged(point);
  }

  /// The typed pair, or null when it is not a point on the globe.
  static GeoPoint? _parseCoordinates(String text) {
    final parts = text.split(',');
    if (parts.length != 2) return null;
    final latitude = double.tryParse(parts[0].trim());
    final longitude = double.tryParse(parts[1].trim());
    if (latitude == null || longitude == null) return null;
    // The same check a Place's own area makes: a value that is not finite, or
    // one so large that scaling it to microdegrees overflows, is not a point
    // at all. Rounding such a value throws.
    if (PlaceArea.create(
          latitudeDegrees: latitude,
          longitudeDegrees: longitude,
        ) ==
        null) {
      return null;
    }
    return (latitudeDegrees: latitude, longitudeDegrees: longitude);
  }

  /// The typed pair becomes the point as soon as it is one.
  ///
  /// **The field is the truth.** A pair that is not a point leaves the Place
  /// without a point, so the surface that holds it cannot quietly save the
  /// point it had before.
  void _onCoordinatesChanged(String text) {
    // The user has chosen a point of their own: a lookup still on its way
    // must not overwrite it.
    _pointRequest++;
    final point = _parseCoordinates(text);
    final had = _point;
    setState(() {
      _message = (text.trim().isEmpty || point != null)
          ? null
          : 'Give a latitude and a longitude, separated by a comma.';
      _point = point;
    });
    if (point != null) {
      widget.onChanged(point);
      return;
    }
    if (had != null) {
      // The typed pair is not a point: the Place has none until it is right
      // again.
      widget.onChanged(null);
    }
  }

  /// The phone's own location. The tap is the user asking for it, so this is
  /// the one place outside the first save where permission may be asked.
  ///
  /// The OS is asked whenever the location is not already allowed: the OS
  /// cannot say whether it was ever asked, so the standing check says only
  /// that the location is not allowed yet.
  Future<void> _useWhereIAm() async {
    final request = ++_pointRequest;
    final source = ref.read(locationSourceProvider);
    var permission = await source.permission();
    if (!permission.isGranted) {
      permission = await source.requestWhileUsing();
    }
    if (!mounted) return;
    // The user chose a point of their own while the OS was answering.
    if (request != _pointRequest) return;
    if (!permission.isGranted) {
      setState(() => _message = permission == LocationPermission.deniedForever
          ? 'The phone will not ask again. Allow the location in the app\'s '
              'settings.'
          : 'The phone will not say where you are.');
      return;
    }
    // A location is read only while Jeeves is on screen, and the OS's own
    // permission dialog takes Jeeves off screen for a moment.
    if (!locationReadAllowedIn(_lifecycleState)) {
      setState(() => _message = 'Jeeves was not on screen, so the phone was '
          'not asked.');
      return;
    }
    final point = await source.freshFix(timeout: const Duration(seconds: 10));
    if (!mounted) return;
    // The user chose a point of their own while the phone was looking.
    if (request != _pointRequest) return;
    if (point == null) {
      setState(() => _message = 'The phone could not find you.');
      return;
    }
    _takePoint(point);
  }

  /// Looks the typed address up with the platform geocoder.
  Future<void> _findAddress() async {
    final address = _address.text.trim();
    if (address.isEmpty) return;
    final request = ++_pointRequest;
    final geocoder = ref.read(addressGeocoderProvider);
    final point = await geocoder.pointForAddress(address);
    if (!mounted) return;
    // The user chose a point of their own while the geocoder was looking.
    if (request != _pointRequest) return;
    if (point == null) {
      setState(() => _message = 'That address is not one I know.');
      return;
    }
    _takePoint(point);
  }

  @override
  Widget build(BuildContext context) {
    final source = ref.watch(locationSourceProvider);
    final geocoder = ref.watch(addressGeocoderProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (source.supportsPermissionPrompt)
          OutlinedButton.icon(
            key: const Key('place_point_use_here'),
            onPressed: _useWhereIAm,
            icon: const Icon(Icons.my_location_outlined, size: 18),
            label: const Text('Use where I am'),
          ),
        if (source.supportsPermissionPrompt) const SizedBox(height: 12),
        if (geocoder.supportsAddressLookup) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  key: const Key('place_point_address'),
                  controller: _address,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Address',
                    hintText: 'Street and town',
                  ),
                  onSubmitted: (_) => _findAddress(),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                key: const Key('place_point_find_address'),
                onPressed: _findAddress,
                child: const Text('Find'),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          key: const Key('place_point_coordinates'),
          controller: _coordinates,
          decoration: const InputDecoration(
            isDense: true,
            labelText: 'Latitude, longitude',
            hintText: '52.37020, 4.89520',
          ),
          onChanged: _onCoordinatesChanged,
        ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _message!,
              key: const Key('place_point_message'),
              style: const TextStyle(fontSize: 12, color: Color(0xFFB91C1C)),
            ),
          ),
      ],
    );
  }
}
