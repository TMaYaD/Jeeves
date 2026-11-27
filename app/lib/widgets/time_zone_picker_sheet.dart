/// The picker for the time zone a place's hours are read on (issue #1074).
///
/// Every zone the tz database knows, searchable by name. The zone a place
/// carries is the clock its hours open and close on, so this is where the
/// user names the place's own clock.
library;

import 'package:flutter/material.dart';

import '../models/place_time_zone.dart';

/// Opens the picker and answers the IANA name the user chose, or null when
/// the user backed out.
Future<String?> showTimeZonePickerSheet(
  BuildContext context, {
  String? current,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    builder: (_) => TimeZonePickerSheet(current: current),
  );
}

/// The picker sheet.
class TimeZonePickerSheet extends StatefulWidget {
  const TimeZonePickerSheet({super.key, this.current});

  /// The zone the place carries now, marked in the list.
  final String? current;

  @override
  State<TimeZonePickerSheet> createState() => _TimeZonePickerSheetState();
}

class _TimeZonePickerSheetState extends State<TimeZonePickerSheet> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  /// Every zone the tz database knows, read once.
  late final List<String> _names = placeTimeZoneNames();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final names = _names
        .where((name) => query.isEmpty || name.toLowerCase().contains(query))
        .toList();
    final height = MediaQuery.of(context).size.height;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          left: 24,
          right: 24,
          top: 24,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: height * 0.7),
          child: ListView.builder(
            itemCount: names.length + 1,
            itemBuilder: (_, i) {
              if (i == 0) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Time zone',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      key: const Key('time_zone_search'),
                      controller: _search,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: 'Search',
                        hintText: 'Europe/Berlin',
                      ),
                      onChanged: (value) => setState(() => _query = value),
                    ),
                    const SizedBox(height: 8),
                  ],
                );
              }
              final name = names[i - 1];
              return ListTile(
                key: Key('time_zone_option_$name'),
                dense: true,
                title: Text(
                  name,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF374151),
                  ),
                ),
                trailing: name == widget.current
                    ? const Icon(
                        Icons.check,
                        size: 18,
                        color: Color(0xFF9CA3AF),
                      )
                    : null,
                onTap: () => Navigator.pop(context, name),
              );
            },
          ),
        ),
      ),
    );
  }
}
