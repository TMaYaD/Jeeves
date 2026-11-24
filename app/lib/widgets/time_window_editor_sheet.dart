/// The named time window editor (issue #55).
///
/// A name and the hours of each day the window is open. The user may give
/// chosen days the same hours, or different hours day by day. An end before
/// the start belongs to the next day, and is labelled as one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../models/time_window_hours.dart';
import '../providers/auth_provider.dart';
import '../providers/database_provider.dart';

/// Opens the editor for [window] — a new one when it is null — and returns the
/// id of the saved window, or null when the user backed out.
Future<String?> showTimeWindowEditorSheet(
  BuildContext context, {
  TimeWindow? window,
  int useCount = 0,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    builder: (ctx) => _TimeWindowEditorSheet(window: window, useCount: useCount),
  );
}

/// How the hours are entered: the same on every chosen day, or day by day.
enum _HoursMode { same, different }

class _TimeWindowEditorSheet extends ConsumerStatefulWidget {
  const _TimeWindowEditorSheet({required this.window, required this.useCount});

  /// The window being edited, or null for a new one.
  final TimeWindow? window;

  /// How many current Actions of active Outcomes use the window — the number
  /// a delete would take away.
  final int useCount;

  @override
  ConsumerState<_TimeWindowEditorSheet> createState() =>
      _TimeWindowEditorSheetState();
}

class _TimeWindowEditorSheetState extends ConsumerState<_TimeWindowEditorSheet> {
  static const _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _defaultStart = 9 * 60;
  static const _defaultEnd = 17 * 60;

  late final TextEditingController _name;
  late _HoursMode _mode;
  final Map<int, DayHours> _hours = {};

  /// Whether a write is running. The Save control is disabled while it is,
  /// so a second tap cannot write a second window.
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final window = widget.window;
    _name = TextEditingController(text: window?.name ?? '');
    final parsed = window == null ? null : TimeWindowHours.tryParse(window.hours);
    final days = parsed?.days ?? const <int>[];
    for (final day in days) {
      _hours[day] = parsed!.hoursForDay(day)!;
    }
    // A window whose hours differ by day opens in the day-by-day editor; one
    // whose days share hours opens in the simpler one.
    final first = days.isEmpty ? null : _hours[days.first];
    _mode = days.isEmpty ||
            days.every((day) => _sameHours(_hours[day]!, first!))
        ? _HoursMode.same
        : _HoursMode.different;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  static bool _sameHours(DayHours a, DayHours b) =>
      a.startMinute == b.startMinute && a.endMinute == b.endMinute;

  /// The hours the "same on chosen days" editor shows, or null when no day is
  /// chosen.
  DayHours? get _sharedHours {
    for (final day in _hours.keys) {
      return _hours[day];
    }
    return null;
  }

  /// The value the sheet would save, or null when it is not yet acceptable.
  TimeWindowHours? get _value {
    final name = _name.text.trim();
    if (name.isEmpty || name.length > TimeWindows.maxNameLength) return null;
    return TimeWindowHours.create(Map.of(_hours));
  }

  String _clock(int minuteOfDay) =>
      '${(minuteOfDay ~/ 60).toString().padLeft(2, '0')}:'
      '${(minuteOfDay % 60).toString().padLeft(2, '0')}';

  Future<void> _pickTime({
    required int initialMinute,
    required void Function(int minute) onPicked,
  }) async {
    // An end of 24:00 (the end of the day) is a valid value but not a
    // TimeOfDay, whose hour is 0–23: the picker opens on 23:59.
    final initial = initialMinute.clamp(0, 24 * 60 - 1);
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: initial ~/ 60,
        minute: initial % 60,
      ),
    );
    if (picked == null) return;
    onPicked(picked.hour * 60 + picked.minute);
  }

  /// The From/To pair of one day, written back through [onChanged].
  Widget _timeRow({
    required int startMinute,
    required int endMinute,
    required void Function(int start, int end) onChanged,
    required String keyPrefix,
  }) {
    final overnight = endMinute < startMinute;
    final invalid = endMinute == startMinute;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton(
              key: Key('${keyPrefix}_start'),
              // The end stays where the user put it: moving the start of an
              // overnight window must not turn it into a daytime one, and an
              // end at or before the new start belongs to the next day, which
              // the row says out loud.
              onPressed: () => _pickTime(
                initialMinute: startMinute,
                onPicked: (picked) => onChanged(picked, endMinute),
              ),
              child: Text(_clock(startMinute)),
            ),
            const Text('and'),
            TextButton(
              key: Key('${keyPrefix}_end'),
              onPressed: () => _pickTime(
                initialMinute: endMinute,
                onPicked: (picked) => onChanged(startMinute, picked),
              ),
              child: Text(_clock(endMinute)),
            ),
            if (overnight)
              const Text(
                'next day',
                style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
              ),
          ],
        ),
        if (invalid)
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Text(
              'The end must differ from the start.',
              style: TextStyle(fontSize: 12, color: Color(0xFFB91C1C)),
            ),
          ),
      ],
    );
  }

  void _setDayHours(Set<int> days, int start, int end) {
    setState(() {
      for (final day in days) {
        _hours[day] = (startMinute: start, endMinute: end);
      }
    });
  }

  Future<void> _save() async {
    // One write at a time: a second tap while the first is running would
    // write a second window.
    if (_saving) return;
    final value = _value;
    if (value == null) return;
    _saving = true;
    if (mounted) setState(() {});
    final db = ref.read(databaseProvider);
    final userId = ref.read(currentUserIdProvider);
    final existing = widget.window;
    String? id;
    try {
      if (existing == null) {
        id = await db.timeWindowDao.createTimeWindow(
          name: _name.text.trim(),
          hours: Map.of(_hours),
          userId: userId,
        );
      } else {
        id = existing.id;
        await db.timeWindowDao.updateTimeWindow(
          windowId: existing.id,
          name: _name.text.trim(),
          hours: Map.of(_hours),
        );
      }
    } on Object {
      // The write did not land: let the user try again.
      _saving = false;
      if (mounted) setState(() {});
      rethrow;
    }
    if (!mounted) return;
    Navigator.pop(context, id);
  }

  Future<void> _confirmDelete() async {
    final existing = widget.window;
    if (existing == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete time window?'),
        content: Text(
          widget.useCount == 0
              ? 'No action uses it.'
              : '${widget.useCount} '
                  '${widget.useCount == 1 ? 'action loses' : 'actions lose'} '
                  'this window.',
        ),
        actions: [
          TextButton(
            key: const Key('time_window_delete_cancel'),
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('time_window_delete_confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(databaseProvider).timeWindowDao.deleteTimeWindow(existing.id);
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final shared = _sharedHours;
    final value = _value;
    final name = _name.text.trim();
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
                widget.window == null ? 'Time window' : 'Edit time window',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('time_window_name'),
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              SegmentedButton<_HoursMode>(
                key: const Key('time_window_mode'),
                segments: const [
                  ButtonSegment(
                    value: _HoursMode.same,
                    label: Text('Same hours', key: Key('time_window_mode_same')),
                  ),
                  ButtonSegment(
                    value: _HoursMode.different,
                    label: Text(
                      'By day',
                      key: Key('time_window_mode_different'),
                    ),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (selection) {
                  final mode = selection.first;
                  setState(() {
                    _mode = mode;
                    // The "same hours" editor shows one pair for every chosen
                    // day, so every chosen day takes that pair: what the sheet
                    // shows is what Save writes.
                    if (mode == _HoursMode.same) {
                      final shared = _sharedHours;
                      if (shared != null) {
                        for (final day in _hours.keys.toList()) {
                          _hours[day] = shared;
                        }
                      }
                    }
                  });
                },
              ),
              const SizedBox(height: 16),
              if (_mode == _HoursMode.same) ...[
                Wrap(
                  spacing: 8,
                  children: [
                    for (var i = 0; i < 7; i++)
                      FilterChip(
                        key: Key('time_window_day_${i + 1}'),
                        label: Text(_dayLabels[i]),
                        selected: _hours.containsKey(i + 1),
                        onSelected: (on) => setState(() {
                          if (on) {
                            _hours[i + 1] = shared ??
                                (startMinute: _defaultStart, endMinute: _defaultEnd);
                          } else {
                            _hours.remove(i + 1);
                          }
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (shared != null)
                  _timeRow(
                    startMinute: shared.startMinute,
                    endMinute: shared.endMinute,
                    keyPrefix: 'time_window',
                    onChanged: (start, end) =>
                        _setDayHours(_hours.keys.toSet(), start, end),
                  ),
              ] else
                for (var day = 1; day <= 7; day++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 44,
                          child: Text(
                            _dayLabels[day - 1],
                            style:
                                const TextStyle(fontWeight: FontWeight.w500),
                          ),
                        ),
                        if (_hours.containsKey(day))
                          Expanded(
                            child: _timeRow(
                              startMinute: _hours[day]!.startMinute,
                              endMinute: _hours[day]!.endMinute,
                              keyPrefix: 'time_window_day_$day',
                              onChanged: (start, end) => setState(() {
                                _hours[day] =
                                    (startMinute: start, endMinute: end);
                              }),
                            ),
                          )
                        else
                          TextButton(
                            key: Key('time_window_day_${day}_on'),
                            onPressed: () => setState(() {
                              _hours[day] = (startMinute: _defaultStart, endMinute: _defaultEnd);
                            }),
                            child: const Text('Closed'),
                          ),
                        if (_hours.containsKey(day))
                          IconButton(
                            key: Key('time_window_day_${day}_off'),
                            tooltip: 'Closed that day',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () => setState(() => _hours.remove(day)),
                          ),
                      ],
                    ),
                  ),
              if (name.isNotEmpty && name.length > TimeWindows.maxNameLength)
                const Padding(
                  padding: EdgeInsets.only(bottom: 4),
                  child: Text(
                    'The name is too long.',
                    style: TextStyle(fontSize: 12, color: Color(0xFFB91C1C)),
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (widget.window != null)
                    TextButton(
                      key: const Key('time_window_delete'),
                      onPressed: _confirmDelete,
                      child: const Text('Delete'),
                    ),
                  const Spacer(),
                  FilledButton(
                    key: const Key('time_window_save'),
                    onPressed: (value == null || _saving) ? null : _save,
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
