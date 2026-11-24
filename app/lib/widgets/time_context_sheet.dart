/// The "Time context" chip and its editor sheet (issue #238): when can the
/// Outcome's current Action be done — from a date, in a weekly window, in one
/// of the user's named time windows, or a combination of the first two.
///
/// Shared by the Task Detail screen and the Daily Planning Outcome peek.
library;

import 'package:flutter/material.dart' hide Action;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart' show TimeWindow;
import '../models/action_place_and_time_window.dart';
import '../models/time_context.dart';
import '../models/time_window_hours.dart';
import '../providers/task_detail_provider.dart';
import '../providers/time_window_provider.dart';
import 'meta_chip.dart';
import 'time_window_editor_sheet.dart';

/// Chip showing the current Action's time — a named window's name, a Time
/// context's description, or a quiet "Time context". Renders nothing for an
/// Actionless Outcome. A stored value the app cannot parse shows as
/// "Unreadable" so the sheet's Clear stays reachable.
class TimeContextChip extends ConsumerWidget {
  const TimeContextChip({super.key, required this.outcomeId});

  final String outcomeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final action = ref.watch(currentActionProvider(outcomeId)).asData?.value;
    if (action == null) return const SizedBox.shrink();
    final windows = ref.watch(currentTimeWindowsProvider).asData?.value ??
        const <String, ActionTimeWindow>{};
    final window = windows[outcomeId];
    final raw = action.timeContext;
    final parsed = TimeContext.tryParse(raw);
    final hasContext = raw != null && raw.trim().isNotEmpty;
    final label = window?.name ??
        parsed?.describe() ??
        (hasContext ? 'Unreadable' : 'Time context');
    final isSet = window != null || hasContext;
    return InkWell(
      key: const Key('time_context_chip'),
      borderRadius: BorderRadius.circular(4),
      onTap: () => showTimeContextSheet(
        context,
        ref.read(taskDetailNotifierProvider(outcomeId)),
        action.id,
        parsed,
        window: window,
        hasStoredValue: isSet,
      ),
      child: MetaChip(
        icon: Icons.event_repeat_outlined,
        label: label,
        color: isSet ? const Color(0xFF0F766E) : const Color(0xFF9CA3AF),
      ),
    );
  }
}

Future<void> showTimeContextSheet(
  BuildContext context,
  TaskDetailNotifier notifier,
  String actionId,
  TimeContext? current, {
  ActionTimeWindow? window,
  bool hasStoredValue = false,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    builder: (ctx) => _TimeContextSheet(
      notifier: notifier,
      actionId: actionId,
      current: current,
      window: window,
      hasStoredValue: hasStoredValue || current != null || window != null,
    ),
  );
}

/// Which kind of time the sheet is offering.
enum _TimeChoice { window, oneTime }

class _TimeContextSheet extends ConsumerStatefulWidget {
  const _TimeContextSheet({
    required this.notifier,
    required this.actionId,
    required this.current,
    required this.window,
    required this.hasStoredValue,
  });

  final TaskDetailNotifier notifier;

  /// The Action the sheet was opened for; saves and clears target them, not
  /// whatever is current when the user confirms.
  final String actionId;
  final TimeContext? current;

  /// The named window the Action carries, if any.
  final ActionTimeWindow? window;
  final bool hasStoredValue;

  @override
  ConsumerState<_TimeContextSheet> createState() => _TimeContextSheetState();
}

class _TimeContextSheetState extends ConsumerState<_TimeContextSheet> {
  static const _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  late _TimeChoice _choice;
  DateTime? _fromDate;
  final Set<int> _days = {};
  int? _startMinute;
  int? _endMinute;

  @override
  void initState() {
    super.initState();
    final c = widget.current;
    if (c != null) {
      _fromDate = c.fromDate;
      _days.addAll(c.days ?? const {});
      _startMinute = c.startMinute;
      _endMinute = c.endMinute;
    }
    // A named window leads: the user chose it last, and the one-time controls
    // are still there behind the other choice.
    _choice =
        widget.window != null ? _TimeChoice.window : _TimeChoice.oneTime;
  }

  TimeContext? get _value => TimeContext.create(
        fromDate: _fromDate,
        days: _days.isEmpty ? null : _days,
        startMinute: _startMinute,
        endMinute: _endMinute,
      );

  String _clock(int? minuteOfDay) => minuteOfDay == null
      ? '—'
      : '${(minuteOfDay ~/ 60).toString().padLeft(2, '0')}:'
          '${(minuteOfDay % 60).toString().padLeft(2, '0')}';

  Future<void> _pickFrom() async {
    final today = DateTime.now();
    final startOfToday = DateTime(today.year, today.month, today.day);
    final lastDate = startOfToday.add(const Duration(days: 365));
    // A stored From date can lie outside [today, today + 365 days] (set
    // earlier, or the device clock moved back); showDatePicker asserts
    // initialDate is in range, so clamp only what the picker opens on.
    var initialDate = _fromDate ?? startOfToday;
    if (initialDate.isBefore(startOfToday)) initialDate = startOfToday;
    if (initialDate.isAfter(lastDate)) initialDate = lastDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: startOfToday,
      lastDate: lastDate,
    );
    if (picked != null) setState(() => _fromDate = picked);
  }

  Future<void> _pickTime({required bool isStart}) async {
    final minuteOfDay = isStart ? _startMinute : _endMinute;
    // An end of 24:00 (end of day) is valid for the value but not for
    // TimeOfDay, whose hour is 0–23: show 23:59 in the picker.
    final initialMinute =
        (minuteOfDay ?? (isStart ? 9 * 60 : 17 * 60)).clamp(0, 24 * 60 - 1);
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: initialMinute ~/ 60,
        minute: initialMinute % 60,
      ),
    );
    if (picked == null) return;
    setState(() {
      final picked24 = picked.hour * 60 + picked.minute;
      if (isStart) {
        _startMinute = picked24;
        _endMinute ??= (picked24 + 60).clamp(0, 24 * 60).toInt();
      } else {
        _endMinute = picked24;
        _startMinute ??= (picked24 - 60).clamp(0, 24 * 60).toInt();
      }
      // A time window needs weekdays: default to every day.
      if (_days.isEmpty) _days.addAll(const [1, 2, 3, 4, 5, 6, 7]);
    });
  }

  Future<void> _save() async {
    final value = _value;
    if (value == null) return;
    Navigator.pop(context);
    await widget.notifier.setTimeContext(value, actionId: widget.actionId);
  }

  /// Clears whichever time the Action carries: a named window or the one-time
  /// Time context.
  Future<void> _clear() async {
    final hasWindow = widget.window != null;
    Navigator.pop(context);
    if (hasWindow) {
      await widget.notifier.setTimeWindow(null, actionId: widget.actionId);
    } else {
      await widget.notifier.setTimeContext(null, actionId: widget.actionId);
    }
  }

  /// Attaches the named window and closes the sheet. A window and a one-time
  /// Time context are exclusive: the write clears the other.
  Future<void> _chooseWindow(String windowId) async {
    Navigator.pop(context);
    await widget.notifier.setTimeWindow(windowId, actionId: widget.actionId);
  }

  /// Makes a new window in the editor, then attaches it.
  Future<void> _newWindow() async {
    final id = await showTimeWindowEditorSheet(context);
    if (id == null || !mounted) return;
    await widget.notifier.setTimeWindow(id, actionId: widget.actionId);
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final hasWindow = _startMinute != null;
    final windows = ref.watch(timeWindowsProvider).asData?.value ??
        const <TimeWindow>[];
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
              const Text('Time context',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text(
                'When this action can be done. Until then the outcome is '
                'hidden from Next and Up Next.',
                style: TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
              ),
              const SizedBox(height: 16),
              SegmentedButton<_TimeChoice>(
                key: const Key('time_context_choice'),
                segments: const [
                  ButtonSegment(
                    value: _TimeChoice.window,
                    label: Text('Time window',
                        key: Key('time_context_choice_window')),
                  ),
                  ButtonSegment(
                    value: _TimeChoice.oneTime,
                    label: Text('One-time',
                        key: Key('time_context_choice_one_time')),
                  ),
                ],
                selected: {_choice},
                onSelectionChanged: (selection) =>
                    setState(() => _choice = selection.first),
              ),
              const SizedBox(height: 12),
              if (_choice == _TimeChoice.window) ...[
                if (windows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'No time windows yet.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)),
                    ),
                  ),
                for (final window in windows)
                  ListTile(
                    key: Key('time_context_window_${window.id}'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(window.name),
                    subtitle: Text(
                      TimeWindowHours.tryParse(window.hours)?.describe() ??
                          'Unreadable hours',
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF9CA3AF)),
                    ),
                    trailing: widget.window?.id == window.id
                        ? const Icon(Icons.check, size: 18)
                        : null,
                    onTap: () => _chooseWindow(window.id),
                  ),
                ListTile(
                  key: const Key('time_context_new_window'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('New window…'),
                  onTap: _newWindow,
                ),
              ] else ...[
                ListTile(
                  key: const Key('time_context_from'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('From'),
                  subtitle: Text(_fromDate == null
                      ? 'Any date'
                      : TimeContext.create(fromDate: _fromDate)!
                          .describe()
                          .replaceFirst('From ', '')),
                  trailing: _fromDate == null
                      ? null
                      : IconButton(
                          key: const Key('time_context_from_clear'),
                          tooltip: 'Clear date',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => setState(() => _fromDate = null),
                        ),
                  onTap: _pickFrom,
                ),
                const Text('Days', style: TextStyle(fontWeight: FontWeight.w500)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (var i = 0; i < 7; i++)
                      FilterChip(
                        key: Key('time_context_day_${i + 1}'),
                        label: Text(_dayLabels[i]),
                        selected: _days.contains(i + 1),
                        onSelected: (on) => setState(() {
                          if (on) {
                            _days.add(i + 1);
                          } else {
                            _days.remove(i + 1);
                            // No days left means no weekly window at all.
                            if (_days.isEmpty) {
                              _startMinute = null;
                              _endMinute = null;
                            }
                          }
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text('Between',
                    style: TextStyle(fontWeight: FontWeight.w500)),
                Row(
                  children: [
                    TextButton(
                      key: const Key('time_context_start'),
                      onPressed: () => _pickTime(isStart: true),
                      child: Text(_clock(_startMinute)),
                    ),
                    const Text('and'),
                    TextButton(
                      key: const Key('time_context_end'),
                      onPressed: () => _pickTime(isStart: false),
                      child: Text(_clock(_endMinute)),
                    ),
                    if (hasWindow)
                      IconButton(
                        key: const Key('time_context_window_clear'),
                        tooltip: 'All day',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => setState(() {
                          _startMinute = null;
                          _endMinute = null;
                        }),
                      ),
                  ],
                ),
                if (hasWindow && _value == null)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 4),
                    child: Text('The end must be after the start.',
                        style: TextStyle(fontSize: 12, color: Color(0xFFB91C1C))),
                  ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  if (widget.hasStoredValue)
                    TextButton(
                      key: const Key('time_context_clear'),
                      onPressed: _clear,
                      child: const Text('Clear time context'),
                    ),
                  const Spacer(),
                  if (_choice == _TimeChoice.oneTime)
                    FilledButton(
                      key: const Key('time_context_save'),
                      onPressed: _value == null ? null : _save,
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
