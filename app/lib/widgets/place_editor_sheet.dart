/// The editor for a named Place: its name, its point, its area and its hours
/// (issue #55, issue #1074).
///
/// The area is how far from the point the user still counts as being there.
/// A new Place takes 150 m, and the user may set it from 50 m to 2 km.
///
/// The hours are optional: the Place takes them from one of the user's named
/// time windows, or carries hours of its own. Either way they are read on the
/// Place's own clock, which the user names in the Time zone row.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/place_dao.dart' show NamedPlaceWithUse;
import '../database/gtd_database.dart';
import '../models/place_area.dart';
import '../models/time_window_hours.dart';
import '../providers/auth_provider.dart';
import '../providers/database_provider.dart';
import '../providers/location_permission_flow.dart';
import '../providers/location_source_provider.dart';
import '../providers/phone_time_zone_provider.dart';
import '../providers/time_window_provider.dart';
import '../services/location_source.dart';
import 'place_area_slider.dart';
import 'place_point_input.dart';
import 'time_window_editor_sheet.dart';
import 'time_zone_picker_sheet.dart';

/// The value the time window dropdown carries for "make a new window".
///
/// A window id is a UUID, so this never names a real window.
const String _newWindowValue = '__new_window__';

/// Where a Place's hours come from.
enum _PlaceHoursChoice {
  /// The Place has no hours.
  none,

  /// The Place takes the hours of a named time window.
  timeWindow,

  /// The Place carries hours of its own.
  own,
}

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

  /// Where the Place's hours come from.
  _PlaceHoursChoice _hoursChoice = _PlaceHoursChoice.none;

  /// The window the Place takes its hours from, when it takes them from one.
  String? _timeWindowId;

  /// The hours the Place carries of its own.
  TimeWindowHours? _ownHours;

  /// The IANA name of the zone the Place's hours are read on.
  ///
  /// Null means the phone's own zone, until the user names another one.
  String? _timeZone;

  /// Whether the user changed the hours or the zone.
  ///
  /// Only then does Save write the hours: a Place whose hours nobody touched
  /// keeps the ones it has, and no op says otherwise.
  bool _hoursTouched = false;

  @override
  void initState() {
    super.initState();
    final place = widget.place;
    if (place != null) {
      _point = (
        latitudeDegrees: place.area.latitudeDegrees,
        longitudeDegrees: place.area.longitudeDegrees,
      );
      final hours = place.hours;
      _timeWindowId = hours.timeWindowId;
      _ownHours = TimeWindowHours.tryParse(hours.ownHoursText);
      _timeZone = hours.timeZone;
      if (hours.timeWindowId != null) {
        _hoursChoice = _PlaceHoursChoice.timeWindow;
      } else if (_ownHours != null) {
        _hoursChoice = _PlaceHoursChoice.own;
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _canSave =>
      _name.text.trim().isNotEmpty && _point != null && !_saving;

  /// The zone the Place's hours are read on: the one the user named, or the
  /// phone's own zone until they name another one.
  ///
  /// The phone's zone is read where it is watched — in the build — and read
  /// again when the Place is saved.
  String? _effectiveZone(String? phoneZone) =>
      _hoursChoice == _PlaceHoursChoice.none
          ? null
          : (_timeZone ?? phoneZone);

  /// Takes the Place's hours from [choice].
  void _chooseHours(_PlaceHoursChoice choice) {
    if (choice == _hoursChoice) {
      // Choosing "Own hours" again opens the hours editor: it is the way to
      // change them.
      if (choice == _PlaceHoursChoice.own) _openOwnHours();
      return;
    }
    setState(() {
      _hoursChoice = choice;
      _hoursTouched = true;
      if (choice == _PlaceHoursChoice.none) {
        _timeWindowId = null;
        _ownHours = null;
      } else if (choice == _PlaceHoursChoice.timeWindow) {
        _ownHours = null;
      } else {
        _timeWindowId = null;
      }
    });
    if (choice == _PlaceHoursChoice.own && _ownHours == null) {
      // There are no hours to edit yet, so the editor opens on its own.
      _openOwnHours();
    }
  }

  /// Opens the hours editor and keeps the hours it answers.
  Future<void> _openOwnHours() async {
    final hours = await showTimeWindowHoursSheet(context, initial: _ownHours);
    if (hours == null || !mounted) return;
    setState(() {
      _ownHours = hours;
      _hoursChoice = _PlaceHoursChoice.own;
      _hoursTouched = true;
    });
  }

  /// Opens the time window editor and keeps the window it answers.
  Future<void> _makeTimeWindow() async {
    final id = await showTimeWindowEditorSheet(context);
    if (id == null || !mounted) return;
    setState(() {
      _timeWindowId = id;
      _hoursChoice = _PlaceHoursChoice.timeWindow;
      _hoursTouched = true;
    });
  }

  /// Opens the time zone picker and keeps the zone it answers.
  Future<void> _pickTimeZone(String? phoneZone) async {
    final chosen = await showTimeZonePickerSheet(
      context,
      current: _effectiveZone(phoneZone),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _timeZone = chosen;
      _hoursTouched = true;
    });
  }

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
    // The hours travel in one write: the window, the hours of the Place's
    // own and the zone they are read on. A Place whose hours nobody touched
    // is not written at all.
    if (_hoursTouched) {
      final phoneZone = ref.read(phoneTimeZoneNameProvider).value;
      await db.placeDao.setPlaceHours(
        placeId: placeId,
        timeWindowId: _hoursChoice == _PlaceHoursChoice.timeWindow
            ? _timeWindowId
            : null,
        hours: _hoursChoice == _PlaceHoursChoice.own ? _ownHours : null,
        timeZone: _effectiveZone(phoneZone),
      );
    }
    if (!mounted) return;
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

  /// The dropdown of the user's named time windows.
  Widget _windowPicker(List<TimeWindow> windows) {
    // A window that is not in the list — deleted on another device — is not
    // chosen: the dropdown shows its hint rather than a value it does not
    // have.
    final chosen = windows.any((window) => window.id == _timeWindowId)
        ? _timeWindowId
        : null;
    return DropdownButton<String>(
      key: const Key('place_hours_window_picker'),
      isExpanded: true,
      value: chosen,
      hint: const Text('Choose a window'),
      items: [
        for (final window in windows)
          DropdownMenuItem(value: window.id, child: Text(window.name)),
        const DropdownMenuItem(
          value: _newWindowValue,
          child: Text('New window…'),
        ),
      ],
      onChanged: (value) {
        if (value == null) return;
        if (value == _newWindowValue) {
          _makeTimeWindow();
          return;
        }
        setState(() {
          _timeWindowId = value;
          _hoursTouched = true;
        });
      },
    );
  }

  /// The row that names the zone the Place's hours are read on.
  Widget _timeZoneRow(String? phoneZone) {
    final zone = _effectiveZone(phoneZone);
    return InkWell(
      key: const Key('place_hours_zone_row'),
      onTap: () => _pickTimeZone(phoneZone),
      child: Row(
        children: [
          const Text('Time zone', style: TextStyle(color: Color(0xFF374151))),
          Expanded(
            child: Text(
              zone ?? 'Phone\'s clock',
              key: const Key('place_hours_zone_value'),
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
            ),
          ),
          const Icon(Icons.chevron_right, size: 18, color: Color(0xFF9CA3AF)),
        ],
      ),
    );
  }

  /// The Hours section: where the Place's hours come from, and the clock
  /// they are read on.
  Widget _hoursSection(List<TimeWindow> windows, String? phoneZone) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Hours',
          style: TextStyle(
            fontWeight: FontWeight.w500,
            color: Color(0xFF374151),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            ChoiceChip(
              key: const Key('place_hours_choice_none'),
              label: const Text('No hours'),
              selected: _hoursChoice == _PlaceHoursChoice.none,
              onSelected: (_) => _chooseHours(_PlaceHoursChoice.none),
            ),
            ChoiceChip(
              key: const Key('place_hours_choice_window'),
              label: const Text('Time window'),
              selected: _hoursChoice == _PlaceHoursChoice.timeWindow,
              onSelected: (_) => _chooseHours(_PlaceHoursChoice.timeWindow),
            ),
            ChoiceChip(
              key: const Key('place_hours_choice_own'),
              label: const Text('Own hours'),
              selected: _hoursChoice == _PlaceHoursChoice.own,
              onSelected: (_) => _chooseHours(_PlaceHoursChoice.own),
            ),
          ],
        ),
        if (_hoursChoice == _PlaceHoursChoice.timeWindow) ...[
          const SizedBox(height: 12),
          _windowPicker(windows),
        ],
        if (_hoursChoice == _PlaceHoursChoice.own) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  _ownHours?.describe() ?? 'No hours set',
                  key: const Key('place_hours_own_label'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF9CA3AF),
                  ),
                ),
              ),
              TextButton(
                key: const Key('place_hours_own_button'),
                onPressed: _openOwnHours,
                child: Text(_ownHours == null ? 'Set hours' : 'Change hours'),
              ),
            ],
          ),
        ],
        if (_hoursChoice != _PlaceHoursChoice.none) ...[
          const SizedBox(height: 12),
          _timeZoneRow(phoneZone),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.place == null;
    final windows =
        ref.watch(timeWindowsProvider).value ?? const <TimeWindow>[];
    final phoneZone = ref.watch(phoneTimeZoneNameProvider).value;
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
              const SizedBox(height: 16),
              _hoursSection(windows, phoneZone),
              const SizedBox(height: 8),
              Row(
                // The Delete button gives up its room before the Save does:
                // on a narrow phone its label shortens rather than the row
                // overflowing.
                mainAxisAlignment:
                    isNew ? MainAxisAlignment.end : MainAxisAlignment.spaceBetween,
                children: [
                  if (!isNew)
                    Flexible(
                      child: TextButton(
                        key: const Key('place_editor_delete'),
                        onPressed: _delete,
                        child: const Text(
                          'Delete place',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
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
