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

class _PlacePointInputState extends ConsumerState<PlacePointInput> {
  final TextEditingController _coordinates = TextEditingController();
  final TextEditingController _address = TextEditingController();

  GeoPoint? _point;
  String? _message;

  @override
  void initState() {
    super.initState();
    _point = widget.initialPoint;
    if (_point != null) _coordinates.text = _formatPoint(_point!);
  }

  @override
  void dispose() {
    _coordinates.dispose();
    _address.dispose();
    super.dispose();
  }

  /// The point as "latitude, longitude", to five decimals — enough to name a
  /// place, short enough to read.
  static String _formatPoint(GeoPoint point) =>
      '${point.latitudeDegrees.toStringAsFixed(5)}, '
      '${point.longitudeDegrees.toStringAsFixed(5)}';

  void _setPoint(GeoPoint? point) {
    setState(() {
      _point = point;
      _message = null;
      if (point == null) {
        _coordinates.clear();
      } else {
        _coordinates.text = _formatPoint(point);
      }
    });
    widget.onChanged(point);
  }

  /// Reads the "latitude, longitude" field. A pair that is not two numbers,
  /// or a point off the globe, is refused.
  void _applyCoordinates() {
    final parts = _coordinates.text.split(',');
    if (parts.length != 2) {
      setState(() => _message = 'Give a latitude and a longitude, separated '
          'by a comma.');
      return;
    }
    final latitude = double.tryParse(parts[0].trim());
    final longitude = double.tryParse(parts[1].trim());
    if (latitude == null || longitude == null) {
      setState(() => _message = 'Give a latitude and a longitude, separated '
          'by a comma.');
      return;
    }
    if (latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) {
      setState(() => _message = 'That point is not on the globe.');
      return;
    }
    _setPoint((latitudeDegrees: latitude, longitudeDegrees: longitude));
  }

  /// The phone's own location. The tap is the user asking for it, so this is
  /// the one place outside the first save where permission may be asked.
  Future<void> _useWhereIAm() async {
    final source = ref.read(locationSourceProvider);
    var permission = await source.permission();
    if (permission == LocationPermission.notAsked) {
      permission = await source.requestWhileUsing();
    }
    if (permission != LocationPermission.whileInUse &&
        permission != LocationPermission.always) {
      setState(() => _message = 'The phone will not say where you are.');
      return;
    }
    final point = await source.freshFix(timeout: const Duration(seconds: 10));
    if (point == null) {
      setState(() => _message = 'The phone could not find you.');
      return;
    }
    _setPoint(point);
  }

  /// Looks the typed address up with the platform geocoder.
  Future<void> _findAddress() async {
    final address = _address.text.trim();
    if (address.isEmpty) return;
    final geocoder = ref.read(addressGeocoderProvider);
    final point = await geocoder.pointForAddress(address);
    if (!mounted) return;
    if (point == null) {
      setState(() => _message = 'That address is not one I know.');
      return;
    }
    _setPoint(point);
  }

  @override
  Widget build(BuildContext context) {
    final source = ref.watch(locationSourceProvider);
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
              onPressed: source.supportsPermissionPrompt ? _findAddress : null,
              child: const Text('Find'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('place_point_coordinates'),
          controller: _coordinates,
          decoration: const InputDecoration(
            isDense: true,
            labelText: 'Latitude, longitude',
            hintText: '52.37020, 4.89520',
          ),
          onSubmitted: (_) => _applyCoordinates(),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const Key('place_point_apply_coordinates'),
            onPressed: _applyCoordinates,
            child: const Text('Set this point'),
          ),
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
