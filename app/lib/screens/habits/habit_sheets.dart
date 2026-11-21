/// The Habit field sheets: Check-in kind, Repeat, Anchor and Pause. Each edits
/// a local copy; Done returns the choice, Cancel and dismissing return null,
/// and nothing is written here.
library;

import 'package:flutter/material.dart';

import '../../database/daos/habit_dao.dart';
import '../../database/gtd_database.dart' show Habit;
import '../../models/habit_commitment.dart';

/// The [HabitCommitmentDraft] that says what [commitment] says.
HabitCommitmentDraft habitDraftOf(HabitCommitment commitment) =>
    HabitCommitmentDraft(
      repeatKind: commitment.repeatKind,
      chosenWeekdays: commitment.chosenWeekdays,
      timesPerPeriod: commitment.timesPerPeriod,
      intervalDays: commitment.intervalDays,
      preferredDays: commitment.preferredDays,
      unitLabel: commitment.unitLabel,
      dailyTargetAmount: commitment.dailyTargetAmount,
    );

/// A short description of a commitment's repeat rule.
String habitRepeatSummary(HabitCommitmentDraft c) {
  switch (c.repeatKind) {
    case HabitRepeatKind.everyDay:
      return 'Every day';
    case HabitRepeatKind.chosenWeekdays:
      return (c.chosenWeekdays ?? const []).map(_weekdayName).join(', ');
    case HabitRepeatKind.timesPerWeek:
      return '${c.timesPerPeriod} times a week';
    case HabitRepeatKind.timesPerMonth:
      return '${c.timesPerPeriod} times a month';
    case HabitRepeatKind.everyNDays:
      return 'Every ${c.intervalDays} days';
  }
}

/// A short description of a commitment's Check-in kind.
String habitCheckInSummary(HabitCommitmentDraft c) =>
    c.dailyTargetAmount == null
    ? 'Done or not'
    : '${_amount(c.dailyTargetAmount!)} ${c.unitLabel}';

String _amount(double value) =>
    value == value.roundToDouble() ? value.round().toString() : '$value';

const _weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
String _weekdayName(int isoDay) => _weekdayNames[isoDay - 1];

Future<T?> _showSheet<T>(BuildContext context, WidgetBuilder builder) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          24 + MediaQuery.viewInsetsOf(ctx).bottom,
        ),
        child: SingleChildScrollView(child: builder(ctx)),
      ),
    );

class _DoneRow extends StatelessWidget {
  const _DoneRow({required this.onDone});
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.end,
    children: [
      TextButton(
        key: const Key('habit_sheet_cancel'),
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('habit_sheet_done'),
        onPressed: onDone,
        child: const Text('Done'),
      ),
    ],
  );
}

class _AppliesNote extends StatelessWidget {
  const _AppliesNote(this.text);
  final String? text;

  @override
  Widget build(BuildContext context) => text == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(text!, style: Theme.of(context).textTheme.bodySmall),
        );
}

// --- Check-in kind ----------------------------------------------------------

/// Opens the Check-in kind sheet. Returns [current] with its target changed.
Future<HabitCommitmentDraft?> showCheckInKindSheet(
  BuildContext context,
  HabitCommitmentDraft current, {
  String? appliesNote,
}) => _showSheet(
  context,
  (_) => _CheckInKindSheet(current: current, note: appliesNote),
);

class _CheckInKindSheet extends StatefulWidget {
  const _CheckInKindSheet({required this.current, this.note});
  final HabitCommitmentDraft current;
  final String? note;

  @override
  State<_CheckInKindSheet> createState() => _CheckInKindSheetState();
}

class _CheckInKindSheetState extends State<_CheckInKindSheet> {
  late bool _measurable = widget.current.dailyTargetAmount != null;
  late final _unit = TextEditingController(text: widget.current.unitLabel);
  late final _target = TextEditingController(
    text: widget.current.dailyTargetAmount == null
        ? ''
        : _amount(widget.current.dailyTargetAmount!),
  );

  @override
  void dispose() {
    _unit.dispose();
    _target.dispose();
    super.dispose();
  }

  double? get _targetValue => double.tryParse(_target.text.trim());

  bool get _valid =>
      !_measurable || (_unit.text.trim().isNotEmpty && (_targetValue ?? 0) > 0);

  void _done() {
    final c = widget.current;
    Navigator.of(context).pop(
      HabitCommitmentDraft(
        repeatKind: c.repeatKind,
        chosenWeekdays: c.chosenWeekdays,
        timesPerPeriod: c.timesPerPeriod,
        intervalDays: c.intervalDays,
        preferredDays: c.preferredDays,
        unitLabel: _measurable ? _unit.text.trim() : null,
        dailyTargetAmount: _measurable ? _targetValue : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Check-in', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
              value: false,
              label: Text('Done or not', key: Key('checkin_kind_binary')),
            ),
            ButtonSegment(
              value: true,
              label: Text('Measured', key: Key('checkin_kind_measurable')),
            ),
          ],
          selected: {_measurable},
          onSelectionChanged: (s) => setState(() => _measurable = s.first),
        ),
        if (_measurable) ...[
          const SizedBox(height: 12),
          TextField(
            key: const Key('checkin_unit'),
            controller: _unit,
            decoration: const InputDecoration(
              labelText: 'Unit (pages, glasses)',
            ),
            onChanged: (_) => setState(() {}),
          ),
          TextField(
            key: const Key('checkin_target'),
            controller: _target,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Target'),
            onChanged: (_) => setState(() {}),
          ),
        ],
        const SizedBox(height: 12),
        _AppliesNote(widget.note),
        _DoneRow(onDone: _valid ? _done : null),
      ],
    );
  }
}

// --- Repeat -----------------------------------------------------------------

/// Opens the Repeat sheet. Returns [current] with its repeat rule changed.
Future<HabitCommitmentDraft?> showRepeatSheet(
  BuildContext context,
  HabitCommitmentDraft current, {
  String? appliesNote,
}) => _showSheet(
  context,
  (_) => _RepeatSheet(current: current, note: appliesNote),
);

const _repeatLabels = {
  HabitRepeatKind.everyDay: 'Every day',
  HabitRepeatKind.chosenWeekdays: 'Chosen weekdays',
  HabitRepeatKind.timesPerWeek: 'Times a week',
  HabitRepeatKind.timesPerMonth: 'Times a month',
  HabitRepeatKind.everyNDays: 'Every N days',
};

class _RepeatSheet extends StatefulWidget {
  const _RepeatSheet({required this.current, this.note});
  final HabitCommitmentDraft current;
  final String? note;

  @override
  State<_RepeatSheet> createState() => _RepeatSheetState();
}

class _RepeatSheetState extends State<_RepeatSheet> {
  late HabitRepeatKind _kind = widget.current.repeatKind;
  late final Set<int> _weekdays = {...?widget.current.chosenWeekdays};
  late final Set<int> _preferredWeekdays = {
    if (widget.current.repeatKind == HabitRepeatKind.timesPerWeek)
      ...?widget.current.preferredDays,
  };
  late final _count = TextEditingController(
    text: (widget.current.timesPerPeriod ?? widget.current.intervalDays ?? '')
        .toString(),
  );
  late final _dates = TextEditingController(
    text: widget.current.repeatKind == HabitRepeatKind.timesPerMonth
        ? (widget.current.preferredDays ?? const []).join(', ')
        : '',
  );

  @override
  void dispose() {
    _count.dispose();
    _dates.dispose();
    super.dispose();
  }

  bool get _needsCount =>
      _kind == HabitRepeatKind.timesPerWeek ||
      _kind == HabitRepeatKind.timesPerMonth ||
      _kind == HabitRepeatKind.everyNDays;

  int? get _countValue => int.tryParse(_count.text.trim());

  /// The preferred dates of a monthly Habit: null when the field is invalid.
  List<int>? get _parsedDates {
    final text = _dates.text.trim();
    if (text.isEmpty) return const [];
    final parts = text.split(RegExp(r'\s*,\s*'));
    final dates = <int>[];
    for (final part in parts) {
      final d = int.tryParse(part);
      if (d == null || d < 1 || d > 31) return null;
      dates.add(d);
    }
    return dates;
  }

  bool get _valid {
    if (_kind == HabitRepeatKind.chosenWeekdays && _weekdays.isEmpty) {
      return false;
    }
    if (_needsCount && (_countValue ?? 0) < 1) return false;
    if (_kind == HabitRepeatKind.timesPerMonth && _parsedDates == null) {
      return false;
    }
    return true;
  }

  void _done() {
    final c = widget.current;
    List<int>? sorted(Iterable<int> days) =>
        days.isEmpty ? null : (days.toList()..sort());
    Navigator.of(context).pop(
      HabitCommitmentDraft(
        repeatKind: _kind,
        chosenWeekdays: _kind == HabitRepeatKind.chosenWeekdays
            ? sorted(_weekdays)
            : null,
        timesPerPeriod:
            _kind == HabitRepeatKind.timesPerWeek ||
                _kind == HabitRepeatKind.timesPerMonth
            ? _countValue
            : null,
        intervalDays: _kind == HabitRepeatKind.everyNDays ? _countValue : null,
        preferredDays: switch (_kind) {
          HabitRepeatKind.timesPerWeek => sorted(_preferredWeekdays),
          HabitRepeatKind.timesPerMonth => sorted(_parsedDates ?? const []),
          _ => null,
        },
        unitLabel: c.unitLabel,
        dailyTargetAmount: c.dailyTargetAmount,
      ),
    );
  }

  Widget _weekdayChips(Set<int> selected) => Wrap(
    spacing: 6,
    children: [
      for (var day = 1; day <= 7; day++)
        FilterChip(
          key: Key('weekday_$day'),
          label: Text(_weekdayName(day)),
          selected: selected.contains(day),
          onSelected: (on) =>
              setState(() => on ? selected.add(day) : selected.remove(day)),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Repeat', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          children: [
            for (final kind in HabitRepeatKind.values)
              ChoiceChip(
                key: Key('repeat_${kind.storedValue}'),
                label: Text(_repeatLabels[kind]!),
                selected: _kind == kind,
                onSelected: (_) => setState(() => _kind = kind),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (_kind == HabitRepeatKind.chosenWeekdays) _weekdayChips(_weekdays),
        if (_needsCount)
          TextField(
            key: const Key('repeat_count'),
            controller: _count,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: _kind == HabitRepeatKind.everyNDays
                  ? 'Every how many days'
                  : 'How many times',
            ),
            onChanged: (_) => setState(() {}),
          ),
        if (_kind == HabitRepeatKind.timesPerWeek) ...[
          const SizedBox(height: 8),
          const Text('Preferred days (a hint)'),
          _weekdayChips(_preferredWeekdays),
        ],
        if (_kind == HabitRepeatKind.timesPerMonth)
          TextField(
            key: const Key('repeat_dates'),
            controller: _dates,
            decoration: const InputDecoration(
              labelText: 'Preferred dates, 1 to 31 (a hint)',
            ),
            onChanged: (_) => setState(() {}),
          ),
        const SizedBox(height: 12),
        _AppliesNote(widget.note),
        _DoneRow(onDone: _valid ? _done : null),
      ],
    );
  }
}

// --- Anchor -----------------------------------------------------------------

/// What the Anchor sheet returns.
class HabitAnchorChoice {
  const HabitAnchorChoice(
    this.kind, {
    this.partOfDay,
    this.clockTime,
    this.anchorHabitId,
  });
  final HabitAnchorKind kind;
  final String? partOfDay;
  final String? clockTime;
  final String? anchorHabitId;
}

/// Opens the Anchor sheet. [candidates] are the Habits that may be followed or
/// preceded without a loop.
Future<HabitAnchorChoice?> showAnchorSheet(
  BuildContext context, {
  required HabitAnchorChoice current,
  required List<Habit> candidates,
}) => _showSheet(
  context,
  (_) => _AnchorSheet(current: current, candidates: candidates),
);

class _AnchorSheet extends StatefulWidget {
  const _AnchorSheet({required this.current, required this.candidates});
  final HabitAnchorChoice current;
  final List<Habit> candidates;

  @override
  State<_AnchorSheet> createState() => _AnchorSheetState();
}

class _AnchorSheetState extends State<_AnchorSheet> {
  late HabitAnchorKind _kind = widget.current.kind;
  late String? _part = widget.current.partOfDay;
  late String? _habitId = widget.current.anchorHabitId;
  late final _time = TextEditingController(text: widget.current.clockTime);

  @override
  void dispose() {
    _time.dispose();
    super.dispose();
  }

  bool get _isHabitKind =>
      _kind == HabitAnchorKind.afterHabit ||
      _kind == HabitAnchorKind.beforeHabit;

  bool get _valid => switch (_kind) {
    HabitAnchorKind.none => true,
    HabitAnchorKind.partOfDay => _part != null,
    HabitAnchorKind.clockTime => habitClockTimePattern.hasMatch(
      _time.text.trim(),
    ),
    _ => _habitId != null && widget.candidates.any((h) => h.id == _habitId),
  };

  void _done() => Navigator.of(context).pop(
    HabitAnchorChoice(
      _kind,
      partOfDay: _kind == HabitAnchorKind.partOfDay ? _part : null,
      clockTime: _kind == HabitAnchorKind.clockTime ? _time.text.trim() : null,
      anchorHabitId: _isHabitKind ? _habitId : null,
    ),
  );

  static const _kindLabels = {
    HabitAnchorKind.none: 'None',
    HabitAnchorKind.partOfDay: 'Part of the day',
    HabitAnchorKind.clockTime: 'Clock time',
    HabitAnchorKind.afterHabit: 'After a Habit',
    HabitAnchorKind.beforeHabit: 'Before a Habit',
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Anchor', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          children: [
            for (final kind in HabitAnchorKind.values)
              ChoiceChip(
                key: Key('anchor_${kind.storedValue}'),
                label: Text(_kindLabels[kind]!),
                selected: _kind == kind,
                onSelected: (_) => setState(() => _kind = kind),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (_kind == HabitAnchorKind.partOfDay)
          Wrap(
            spacing: 6,
            children: [
              for (final part in habitPartsOfDay.toList()..sort())
                ChoiceChip(
                  key: Key('anchor_part_$part'),
                  label: Text(part),
                  selected: _part == part,
                  onSelected: (_) => setState(() => _part = part),
                ),
            ],
          ),
        if (_kind == HabitAnchorKind.clockTime)
          TextField(
            key: const Key('anchor_clock_time'),
            controller: _time,
            decoration: const InputDecoration(labelText: 'Time, HH:MM'),
            onChanged: (_) => setState(() {}),
          ),
        if (_isHabitKind)
          if (widget.candidates.isEmpty)
            const Text('No other active Habit can be followed.')
          else
            Column(
              children: [
                for (final habit in widget.candidates)
                  ListTile(
                    key: Key('anchor_candidate_${habit.id}'),
                    dense: true,
                    title: Text(habit.title),
                    selected: _habitId == habit.id,
                    trailing: _habitId == habit.id
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () => setState(() => _habitId = habit.id),
                  ),
              ],
            ),
        const SizedBox(height: 12),
        _DoneRow(onDone: _valid ? _done : null),
      ],
    );
  }
}

// --- Pause ------------------------------------------------------------------

/// What the Pause sheet returns: the day the Habit is active again, or null
/// for a pause with no end.
class HabitPauseChoice {
  const HabitPauseChoice(this.resumesOn);
  final String? resumesOn;
}

/// Opens the Pause sheet. The optional end date is "Resumes on", from
/// tomorrow on.
Future<HabitPauseChoice?> showPauseSheet(
  BuildContext context, {
  required DateTime today,
}) => _showSheet(context, (_) => _PauseSheet(today: today));

class _PauseSheet extends StatefulWidget {
  const _PauseSheet({required this.today});
  final DateTime today;

  @override
  State<_PauseSheet> createState() => _PauseSheetState();
}

class _PauseSheetState extends State<_PauseSheet> {
  DateTime? _resumesOn;

  @override
  Widget build(BuildContext context) {
    final tomorrow = DateTime(
      widget.today.year,
      widget.today.month,
      widget.today.day + 1,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Pause', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        ListTile(
          key: const Key('pause_resumes_on'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Resumes on'),
          subtitle: Text(
            _resumesOn == null ? 'No end date' : habitDayKey(_resumesOn!),
          ),
          trailing: _resumesOn == null
              ? null
              : IconButton(
                  key: const Key('pause_clear_date'),
                  icon: const Icon(Icons.clear),
                  onPressed: () => setState(() => _resumesOn = null),
                ),
          onTap: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: _resumesOn ?? tomorrow,
              firstDate: tomorrow,
              lastDate: DateTime(tomorrow.year + 5),
            );
            if (picked != null) setState(() => _resumesOn = picked);
          },
        ),
        _DoneRow(
          onDone: () => Navigator.of(context).pop(
            HabitPauseChoice(
              _resumesOn == null ? null : habitDayKey(_resumesOn!),
            ),
          ),
        ),
      ],
    );
  }
}
