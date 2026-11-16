import 'package:flutter/material.dart';

import '../../models/autoflow.dart';

/// What the user chose in the Set-the-time sheet. A null [startAt] means
/// "Let Jeeves move it": the pin is cleared.
class SetTimeChoice {
  const SetTimeChoice(this.startAt);

  final DateTime? startAt;
}

/// Opens the Set-the-time sheet and returns the choice, or null when it was
/// dismissed. Reached from the tray's "Set the time", from a tile and from a
/// drop on the timeline (which passes the drop position as [initialStart]).
///
/// [freeGaps] are the stretches no other tile or event covers; the ones that
/// hold [estimateMinutes] are offered as "Place here". [events] are the
/// calendar events, empty with no calendar: only then does the overlap switch
/// and its two choices appear.
Future<SetTimeChoice?> showSetTimeSheet(
  BuildContext context, {
  required String title,
  required int estimateMinutes,
  required DateTime initialStart,
  required List<BusyInterval> freeGaps,
  List<BusyInterval> events = const [],
  bool isPinned = false,
}) {
  return showModalBottomSheet<SetTimeChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => SetTimeSheet(
      title: title,
      estimateMinutes: estimateMinutes,
      initialStart: initialStart,
      freeGaps: freeGaps,
      events: events,
      isPinned: isPinned,
    ),
  );
}

class SetTimeSheet extends StatefulWidget {
  const SetTimeSheet({
    super.key,
    required this.title,
    required this.estimateMinutes,
    required this.initialStart,
    required this.freeGaps,
    this.events = const [],
    this.isPinned = false,
  });

  final String title;
  final int estimateMinutes;
  final DateTime initialStart;
  final List<BusyInterval> freeGaps;
  final List<BusyInterval> events;
  final bool isPinned;

  @override
  State<SetTimeSheet> createState() => _SetTimeSheetState();
}

class _SetTimeSheetState extends State<SetTimeSheet> {
  static const _stepMinutes = 15;

  late DateTime _start = widget.initialStart;
  bool _allowOverlap = false;

  DateTime get _end => _start.add(Duration(minutes: widget.estimateMinutes));

  bool get _overlapsEvent =>
      widget.events.any((event) => event.overlaps(_start, _end));

  /// The start of the first gap at or after the chosen time that holds the
  /// whole estimate; null when there is none.
  DateTime? get _nextFreeStart {
    for (final gap in widget.freeGaps) {
      final from = gap.start.isBefore(_start) ? _start : gap.start;
      if (gap.end.difference(from).inMinutes >= widget.estimateMinutes) {
        return from;
      }
    }
    return null;
  }

  String _clock(DateTime time) =>
      MaterialLocalizations.of(context).formatTimeOfDay(
        TimeOfDay.fromDateTime(time),
        alwaysUse24HourFormat: false,
      );

  void _move(int minutes) =>
      setState(() => _start = _start.add(Duration(minutes: minutes)));

  void _done(DateTime? startAt) =>
      Navigator.of(context).pop(SetTimeChoice(startAt));

  @override
  Widget build(BuildContext context) {
    final roomyGaps = [
      for (final gap in widget.freeGaps)
        if (gap.end.difference(gap.start).inMinutes >= widget.estimateMinutes)
          gap,
    ];
    final nextFree = _nextFreeStart;
    final blockedByEvent = _overlapsEvent && !_allowOverlap;

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Set the time',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(widget.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, color: Colors.grey[700])),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  key: const Key('set_time_earlier'),
                  tooltip: 'Earlier',
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => _move(-_stepMinutes),
                ),
                Column(
                  children: [
                    Text(
                      _clock(_start),
                      key: const Key('set_time_value'),
                      style: const TextStyle(
                          fontSize: 28, fontWeight: FontWeight.w700),
                    ),
                    Text('to ${_clock(_end)} · ${widget.estimateMinutes} min',
                        style:
                            TextStyle(fontSize: 12, color: Colors.grey[600])),
                  ],
                ),
                IconButton(
                  key: const Key('set_time_later'),
                  tooltip: 'Later',
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: () => _move(_stepMinutes),
                ),
              ],
            ),
            if (roomyGaps.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Free time',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600])),
              for (var i = 0; i < roomyGaps.length; i++)
                ListTile(
                  key: Key('set_time_gap_$i'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                      '${_clock(roomyGaps[i].start)} – ${_clock(roomyGaps[i].end)}'),
                  trailing: TextButton(
                    onPressed: () =>
                        setState(() => _start = roomyGaps[i].start),
                    child: const Text('Place here'),
                  ),
                ),
            ],
            if (widget.events.isNotEmpty)
              SwitchListTile(
                key: const Key('set_time_allow_overlap'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Allow overlap with events'),
                value: _allowOverlap,
                onChanged: (value) => setState(() => _allowOverlap = value),
              ),
            const SizedBox(height: 12),
            if (blockedByEvent) ...[
              const Text('This time overlaps an event.'),
              const SizedBox(height: 8),
              if (nextFree != null)
                FilledButton(
                  key: const Key('set_time_place_next'),
                  onPressed: () => _done(nextFree),
                  child: Text('Place at ${_clock(nextFree)}'),
                ),
              OutlinedButton(
                key: const Key('set_time_keep'),
                onPressed: () => _done(_start),
                child: Text('Keep ${_clock(_start)}'),
              ),
            ] else
              FilledButton(
                key: const Key('set_time_confirm'),
                onPressed: () => _done(_start),
                child: const Text('Set time'),
              ),
            if (widget.isPinned)
              TextButton(
                key: const Key('set_time_clear'),
                onPressed: () => _done(null),
                child: const Text('Let Jeeves move it'),
              ),
          ],
        ),
      ),
    );
  }
}
