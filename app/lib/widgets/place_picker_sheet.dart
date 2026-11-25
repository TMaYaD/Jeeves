/// The picker for the Place of an Action (issue #55).
///
/// The user's named places, most recently used first, with a name search; a
/// one-time pin for a single errand; a new place; and a way to clear the
/// Place altogether.
///
/// The picker writes nothing: it answers with the choice the user made, and
/// the surface that opened it applies it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/place_choice.dart';
import '../providers/places_provider.dart';
import 'place_editor_sheet.dart';
import 'place_pin_sheet.dart';

/// Opens the picker and answers the choice the user made.
///
/// Null means the user backed out without choosing. [canClear] says whether
/// "Clear place" is on offer: it is when there is a Place to clear.
Future<PlaceChoice?> showPlacePickerSheet(
  BuildContext context, {
  required bool canClear,
  String pinSubtitle = 'For this action alone',
}) {
  return showModalBottomSheet<PlaceChoice>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    builder: (_) => PlacePickerSheet(canClear: canClear, pinSubtitle: pinSubtitle),
  );
}

/// The picker sheet.
class PlacePickerSheet extends ConsumerStatefulWidget {
  const PlacePickerSheet({
    super.key,
    required this.canClear,
    this.pinSubtitle = 'For this action alone',
  });

  /// What the one-time pin row says it belongs to.
  final String pinSubtitle;

  /// Whether the user may clear the Place outright.
  final bool canClear;

  @override
  ConsumerState<PlacePickerSheet> createState() => _PlacePickerSheetState();
}

class _PlacePickerSheetState extends ConsumerState<PlacePickerSheet> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _chooseNamedPlace(String placeId, String name) {
    Navigator.pop(context, NamedPlaceDraft(placeId, name));
  }

  Future<void> _dropPin() async {
    final pin = await showPlacePinSheet(context);
    if (pin == null || !mounted) return;
    Navigator.pop(context, PinDraft(area: pin.area, name: pin.name));
  }

  Future<void> _makeNewPlace() async {
    final saved = await showPlaceEditorSheet(context);
    if (saved == null || !mounted) return;
    Navigator.pop(context, NamedPlaceDraft(saved.id, saved.name));
  }

  void _clearPlace() {
    Navigator.pop(context, const ClearPlaceChoice());
  }

  @override
  Widget build(BuildContext context) {
    final places = ref.watch(namedPlacesWithUseCountProvider);
    final query = _query.trim().toLowerCase();
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
              const Text('Place',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              TextField(
                key: const Key('place_picker_search'),
                controller: _search,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Search',
                  hintText: 'Home',
                  prefixIcon: Icon(Icons.search, size: 18),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
              const SizedBox(height: 8),
              places.when(
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, s) => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('Could not load your places'),
                ),
                data: (rows) {
                  final matching = [
                    for (final row in rows)
                      if (query.isEmpty || row.name.toLowerCase().contains(query))
                        row,
                  ];
                  if (matching.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'No place of that name.',
                        style: TextStyle(color: Color(0xFF9CA3AF)),
                      ),
                    );
                  }
                  return Column(
                    children: [
                      for (final row in matching)
                        ListTile(
                          key: Key('place_picker_place_${row.id}'),
                          contentPadding: EdgeInsets.zero,
                          title: Text(row.name),
                          subtitle: Text(
                            '${row.area.radiusMeters} m',
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF9CA3AF)),
                          ),
                          onTap: () => _chooseNamedPlace(row.id, row.name),
                        ),
                    ],
                  );
                },
              ),
              const Divider(height: 24, color: Color(0xFFF3F4F6)),
              ListTile(
                key: const Key('place_picker_new_place'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.add_location_alt_outlined),
                title: const Text('New place…'),
                onTap: _makeNewPlace,
              ),
              ListTile(
                key: const Key('place_picker_drop_pin'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.push_pin_outlined),
                title: const Text('Drop a pin…'),
                subtitle: Text(widget.pinSubtitle),
                onTap: _dropPin,
              ),
              if (widget.canClear)
                ListTile(
                  key: const Key('place_picker_clear'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.close),
                  title: const Text('Clear place'),
                  onTap: _clearPlace,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
