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

/// A named Place the editor saved: its id and the name it was saved under.
typedef SavedPlace = ({String id, String name});

/// Opens the editor for a named Place and answers the Place when it is saved.
///
/// [place] is null for a new Place. The sheet is dismissed without an answer
/// when the user backs out of it.
Future<SavedPlace?> showPlaceEditorSheet(
  BuildContext context, {
  NamedPlaceWithUse? place,
}) {
  return showModalBottomSheet<SavedPlace>(
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
  /// The radius the Place has, in metres.
  ///
  /// Kept exactly as it is stored: a radius that came from another device is
  /// not rewritten to the step the slider happens to sit at unless the user
  /// moves the slider.
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
    // The name this save writes, and answers with. Read before the first
    // await: a name typed while the write is in flight must not change what
    // was saved, nor what the caller is told was saved.
    final name = _name.text.trim();
    if (point == null || name.isEmpty) return;
    setState(() => _saving = true);
    // Read before the first await: this widget does not survive the write.
    final source = ref.read(locationSourceProvider);
    final db = ref.read(databaseProvider);
    final userId = ref.read(currentUserIdProvider);
    final place = widget.place;
    String? placeId;
    var saved = false;
    if (place == null) {
      placeId = await db.placeDao.createNamedPlace(
        name: name,
        latitudeDegrees: point.latitudeDegrees,
        longitudeDegrees: point.longitudeDegrees,
        radiusMeters: _radiusMeters,
        userId: userId,
      );
      saved = placeId != null;
    } else {
      placeId = place.id;
      saved = await db.placeDao.updateNamedPlace(
        placeId: place.id,
        name: name,
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
    // before the sheet closes, so its own dialog has a live context. A Place
    // that was not written is no Place saved, so it asks nothing.
    if (saved) {
      await askForLocationAfterFirstSave(context, source);
    }
    if (!mounted) return;
    Navigator.pop(context, (id: placeId, name: name));
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
    // A deleted Place is not a saved Place: the editor answers nothing.
    Navigator.pop(context);
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
              if (_point == null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Set a point to save this place.',
                    key: const Key('place_editor_no_point'),
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF6B7280)),
                  ),
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
