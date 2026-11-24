/// The editor for a named Place: its name, its point and its area (issue #55).
///
/// The area is how far from the point the user still counts as being there.
/// A new Place takes 150 m, and the user may set it from 50 m to 2 km.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/place_dao.dart' show NamedPlaceWithUse;
import '../models/place_area.dart';
import '../providers/auth_provider.dart';
import '../providers/database_provider.dart';
import '../providers/location_permission_flow.dart';
import '../providers/location_source_provider.dart';
import '../services/location_source.dart';
import 'place_area_slider.dart';
import 'place_point_input.dart';

/// Opens the editor for a named Place and answers its id when it is saved.
///
/// [place] is null for a new Place. The sheet is dismissed without an answer
/// when the user backs out of it.
Future<String?> showPlaceEditorSheet(
  BuildContext context, {
  NamedPlaceWithUse? place,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    builder: (_) => PlaceEditorSheet(place: place),
  );
}

/// The editor sheet for a named Place.
class PlaceEditorSheet extends ConsumerStatefulWidget {
  const PlaceEditorSheet({super.key, this.place});

  /// The Place being edited, or null for a new one.
  final NamedPlaceWithUse? place;

  @override
  ConsumerState<PlaceEditorSheet> createState() => _PlaceEditorSheetState();
}

class _PlaceEditorSheetState extends ConsumerState<PlaceEditorSheet> {
  late final TextEditingController _name =
      TextEditingController(text: widget.place?.name ?? '');

  GeoPoint? _point;
  late int _radiusMeters = widget.place?.area.radiusMeters ??
      PlaceArea.defaultRadiusMeters;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final place = widget.place;
    if (place != null) {
      _point = (
        latitudeDegrees: place.area.latitudeDegrees,
        longitudeDegrees: place.area.longitudeDegrees,
      );
    }
    // The slider runs in steps of 50 m, so a radius stored from elsewhere is
    // shown at the step nearest it.
    _radiusMeters = nearestPlaceAreaStep(_radiusMeters);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _canSave =>
      _name.text.trim().isNotEmpty && _point != null && !_saving;

  Future<void> _save() async {
    final point = _point;
    if (point == null || _name.text.trim().isEmpty) return;
    setState(() => _saving = true);
    // Read before the first await: this widget does not survive the write.
    final source = ref.read(locationSourceProvider);
    final db = ref.read(databaseProvider);
    final userId = ref.read(currentUserIdProvider);
    final place = widget.place;
    String? placeId;
    if (place == null) {
      placeId = await db.placeDao.createNamedPlace(
        name: _name.text,
        latitudeDegrees: point.latitudeDegrees,
        longitudeDegrees: point.longitudeDegrees,
        radiusMeters: _radiusMeters,
        userId: userId,
      );
    } else {
      placeId = place.id;
      await db.placeDao.updateNamedPlace(
        placeId: place.id,
        name: _name.text,
        latitudeDegrees: point.latitudeDegrees,
        longitudeDegrees: point.longitudeDegrees,
        radiusMeters: _radiusMeters,
      );
    }
    if (!mounted) return;
    if (placeId == null) {
      setState(() => _saving = false);
      return;
    }
    // The first saved Place is the first time Jeeves may ask for the
    // location — and the only time outside "Use where I am". The ask happens
    // before the sheet closes, so its own dialog has a live context.
    await askForLocationAfterFirstSave(context, source);
    if (!mounted) return;
    Navigator.pop(context, placeId);
  }

  Future<void> _delete() async {
    final place = widget.place;
    if (place == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final consequence = place.useCount == 0
            ? 'No Action uses it.'
            : place.useCount == 1
                ? '1 Action will lose it.'
                : '${place.useCount} Actions will lose it.';
        return AlertDialog(
          title: Text('Delete ${place.name}?'),
          content: Text('$consequence This cannot be undone.'),
          actions: [
            TextButton(
              key: const Key('place_editor_delete_cancel'),
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Keep'),
            ),
            FilledButton(
              key: const Key('place_editor_delete_confirm'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    final db = ref.read(databaseProvider);
    await db.placeDao.deletePlace(place.id);
    if (!mounted) return;
    Navigator.pop(context, place.id);
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.place == null;
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
              Text(
                isNew ? 'New place' : 'Place',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('place_editor_name'),
                controller: _name,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Name',
                  hintText: 'Home',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              PlacePointInput(
                key: const Key('place_editor_point'),
                initialPoint: _point,
                onChanged: (point) => setState(() => _point = point),
              ),
              const SizedBox(height: 16),
              PlaceAreaSlider(
                radiusMeters: _radiusMeters,
                onChanged: (meters) =>
                    setState(() => _radiusMeters = meters),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (!isNew)
                    TextButton(
                      key: const Key('place_editor_delete'),
                      onPressed: _delete,
                      child: const Text('Delete place'),
                    ),
                  const Spacer(),
                  FilledButton(
                    key: const Key('place_editor_save'),
                    onPressed: _canSave ? _save : null,
                    child: const Text('Save'),
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
