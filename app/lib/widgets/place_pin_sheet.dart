/// The sheet for dropping a one-time pin on an Action (issue #55).
///
/// A pin is a Place of that one Action: it is never listed anywhere, and it
/// goes when the Action stops pointing at it. It may carry a short name of
/// its own; without one it reads as "Pin".
library;

import 'package:flutter/material.dart';

import '../models/place_area.dart';
import '../services/location_source.dart';
import 'place_area_slider.dart';
import 'place_point_input.dart';

/// A pin the user has chosen: where it is, how far it reaches, and the short
/// name it may carry.
typedef PinChoice = ({PlaceArea area, String? name});

/// Opens the pin sheet and answers the pin the user chose, or null when they
/// backed out.
Future<PinChoice?> showPlacePinSheet(BuildContext context) {
  return showModalBottomSheet<PinChoice>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    builder: (_) => const PlacePinSheet(),
  );
}

/// The pin sheet.
class PlacePinSheet extends StatefulWidget {
  const PlacePinSheet({super.key});

  @override
  State<PlacePinSheet> createState() => _PlacePinSheetState();
}

class _PlacePinSheetState extends State<PlacePinSheet> {
  final TextEditingController _name = TextEditingController();
  GeoPoint? _point;
  int _radiusMeters = PlaceArea.defaultRadiusMeters;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final point = _point;
    if (point == null) return;
    final area = PlaceArea.create(
      latitudeDegrees: point.latitudeDegrees,
      longitudeDegrees: point.longitudeDegrees,
      radiusMeters: _radiusMeters,
    );
    if (area == null) return;
    final name = _name.text.trim();
    Navigator.pop(
      context,
      (area: area, name: name.isEmpty ? null : name),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          left: 24,
          right: 24,
          top: 24,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Drop a pin',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text(
                'A pin belongs to this action alone.',
                style: TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('place_pin_name'),
                controller: _name,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Name (optional)',
                  hintText: 'Post office on Mill St',
                ),
              ),
              const SizedBox(height: 16),
              PlacePointInput(
                key: const Key('place_pin_point'),
                onChanged: (point) => setState(() => _point = point),
              ),
              const SizedBox(height: 16),
              PlaceAreaSlider(
                radiusMeters: _radiusMeters,
                onChanged: (meters) => setState(() => _radiusMeters = meters),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Spacer(),
                  FilledButton(
                    key: const Key('place_pin_save'),
                    onPressed: _point == null ? null : _save,
                    child: const Text('Drop pin'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
