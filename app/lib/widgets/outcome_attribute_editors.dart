/// Attribute editors shared by the Task Detail screen and the Daily Planning
/// Outcome peek: time estimate, energy and context-tag sheets, and the due-date
/// picker. A behaviour-preserving move out of `task_detail_screen.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../models/estimate.dart';
import '../providers/task_detail_provider.dart';
import 'context_tag_picker.dart';
import 'meta_chip.dart';
import 'timeboxed_glyph.dart';

void showOutcomeContextTagEditor(BuildContext context, String todoId) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom + 24, left: 24, right: 24, top: 24),
      child: SingleChildScrollView(
       child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Edit Context Tags', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          Consumer(
            builder: (context, ref, _) {
              final tags =
                  ref.watch(taskTagsProvider(todoId)).asData?.value ??
                      const <Tag>[];
              final contextTags =
                  tags.where((t) => t.type == 'context').toList();
              return ContextTagPickerWidget(
                cloudInitiallyOpen: true,
                assignedTags: contextTags,
                onAssign: (tag) =>
                    ref
                        .read(taskDetailNotifierProvider(todoId))
                        .assignContextTag(tag.id)
                        .ignore(),
                onRemove: (tag) =>
                    ref
                        .read(taskDetailNotifierProvider(todoId))
                        .removeContextTag(tag.id)
                        .ignore(),
              );
            },
          ),
        ],
       ),
      ),
    ),
  );
}

/// The estimate sheet: the estimate, and whether it is a limit.
///
/// A stepper rather than a list of options, because the sheet now carries a
/// second decision — **Timeboxed** (issue #923) — and a list of options
/// leaves no room for it. The steps walk the shared ladder, so an estimate
/// set here means the same minutes as one set on any other surface.
///
/// The switch belongs to the Action, so it is written through [actionId]; the
/// estimate belongs to the Outcome and is written through the notifier. Both
/// are written together, in one transaction with one timestamp. With no
/// estimate there is nothing to limit, so the switch is unavailable — and
/// clearing the estimate clears the switch with it.
///
/// [initial] opens the sheet on a value other than the stored one — the
/// gate's "Raise the estimate…" opens it one step up. Saving writes that
/// value; cancelling writes nothing.
///
/// Returns whether the sheet was saved.
Future<bool> showOutcomeTimeEstimateSheet(
  BuildContext context,
  TaskDetailNotifier notifier, {
  required int? current,
  int? initial,
  String? actionText,
  String? actionId,
  bool timeboxed = false,
}) async {
  final saved = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.white,
    isScrollControlled: true,
    builder: (ctx) => _EstimateSheet(
      notifier: notifier,
      current: current,
      initial: initial,
      actionText: actionText,
      actionId: actionId,
      timeboxed: timeboxed,
    ),
  );
  return saved ?? false;
}

/// The sheet's body: a stepper over the estimate ladder and the Timeboxed
/// switch beside it.
class _EstimateSheet extends StatefulWidget {
  const _EstimateSheet({
    required this.notifier,
    required this.current,
    required this.timeboxed,
    this.initial,
    this.actionText,
    this.actionId,
  });

  final TaskDetailNotifier notifier;

  /// The estimate as it stands now; null when there is none.
  final int? current;

  /// The value the sheet opens on, when it is not the stored one.
  final int? initial;

  /// The Action the Timeboxed switch belongs to; null where there is none to
  /// write (an Outcome with no current Action).
  final String? actionId;

  /// The Action's title, for the sheet's heading.
  final String? actionText;

  /// Whether the Action's estimate is a limit right now.
  final bool timeboxed;

  @override
  State<_EstimateSheet> createState() => _EstimateSheetState();
}

class _EstimateSheetState extends State<_EstimateSheet> {
  /// The estimate as the sheet holds it: exactly what is stored, until the
  /// user steps it onto the ladder — or the value the sheet was opened on.
  late int? _minutes = widget.initial ?? widget.current;

  /// Whether the estimate has moved. Until it does, saving leaves the stored
  /// value alone: an estimate that is merely being given a Timeboxed switch
  /// must not be quietly rewritten.
  late bool _stepped =
      widget.initial != null && widget.initial != widget.current;

  /// The switch as the sheet holds it. Off whenever there is no estimate to
  /// limit.
  late bool _timeboxed = widget.timeboxed;

  bool get _hasEstimate => _minutes != null;

  /// Whether the ladder has a step above the current value.
  bool get _atTop => _minutes != null && stepEstimateUp(_minutes) == null;

  void _stepDown() {
    setState(() {
      _minutes = stepEstimateDown(_minutes);
      _stepped = true;
      // No estimate, no limit to mark.
      if (_minutes == null) _timeboxed = false;
    });
  }

  void _stepUp() {
    setState(() {
      final next = stepEstimateUp(_minutes);
      // At the top of the ladder there is nowhere to go; the estimate stands.
      if (next == null) return;
      _minutes = next;
      _stepped = true;
    });
  }

  Future<void> _save() async {
    final notifier = widget.notifier;
    final estimateMoved = _stepped && _minutes != widget.current;
    final switchMoved = _hasEstimate && _timeboxed != widget.timeboxed;
    if (estimateMoved || switchMoved) {
      // One write, so the estimate and the switch land together.
      await notifier.setEstimateAndTimeboxed(
        actionId: widget.actionId ?? '',
        minutes: estimateMoved ? _minutes : null,
        clearEstimate: estimateMoved && _minutes == null,
        timeboxed: switchMoved ? _timeboxed : null,
      );
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.actionText == null
                  ? 'Estimate'
                  : 'Estimate · ${widget.actionText}',
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                IconButton(
                  key: const Key('estimate_sheet_less'),
                  onPressed: _hasEstimate ? _stepDown : null,
                  icon: const Icon(Icons.remove),
                  tooltip: 'Less',
                ),
                Expanded(
                  child: Center(
                    child: Text(
                      key: const Key('estimate_sheet_value'),
                      _hasEstimate
                          ? formatMinutesLabel(_minutes!)
                          : 'No estimate',
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('estimate_sheet_more'),
                  onPressed: _atTop ? null : _stepUp,
                  icon: const Icon(Icons.add),
                  tooltip: 'More',
                ),
                const SizedBox(width: 16),
                _TimeboxedToggle(
                  value: _timeboxed,
                  enabled: _hasEstimate && widget.actionId != null,
                  disabledReason: !_hasEstimate
                      ? 'Set an estimate first — there is nothing to limit '
                          'without one.'
                      : 'This Outcome has no current Action to limit.',
                  onChanged: (value) => setState(() => _timeboxed = value),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  key: const Key('estimate_sheet_cancel'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  key: const Key('estimate_sheet_save'),
                  onPressed: _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2667B7),
                  ),
                  child: const Text('Very good'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The Timeboxed switch: the mark of a limit, pressed or not.
///
/// The mark is the estimate's own glyph; the press is the switch. With no
/// estimate — or no Action to hold the switch — there is nothing to limit, so
/// the switch is unavailable, and says why.
class _TimeboxedToggle extends StatelessWidget {
  const _TimeboxedToggle({
    required this.value,
    required this.enabled,
    required this.disabledReason,
    required this.onChanged,
  });

  final bool value;
  final bool enabled;

  /// Why the switch is unavailable, when it is.
  final String disabledReason;

  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    const on = Color(0xFF2563EB);
    const off = Color(0xFF9CA3AF);
    final ink = enabled && value ? on : off;
    return Tooltip(
      message: enabled
          ? 'Timeboxed: treat the estimate as a limit. Each sprint past it '
              'is discouraged.'
          : disabledReason,
      child: InkWell(
        key: const Key('estimate_sheet_timeboxed'),
        onTap: enabled ? () => onChanged(!value) : null,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: value && enabled ? on.withValues(alpha: 0.08) : null,
            borderRadius: BorderRadius.circular(4),
          ),
          child: TimeboxedGlyph(size: 16, color: ink),
        ),
      ),
    );
  }
}

Future<void> showOutcomeEnergyLevelSheet(
    BuildContext context, TaskDetailNotifier notifier, String? current) async {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.white,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Energy Level', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            SegmentedButton<String?>(
              segments: const [
                ButtonSegment(value: 'low', label: Text('Low')),
                ButtonSegment(value: 'medium', label: Text('Medium')),
                ButtonSegment(value: 'high', label: Text('High')),
              ],
              selected: {current},
              emptySelectionAllowed: true,
              onSelectionChanged: (s) {
                if (s.isEmpty || s.first == null) {
                  notifier.clearEnergyLevel();
                } else {
                  notifier.setEnergyLevel(s.first!);
                }
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    ),
  );
}


/// Opens the due-date picker. Returns the picked date, or null when dismissed
/// (which means "no change", not "clear the date").
Future<DateTime?> pickOutcomeDueDate(BuildContext context, DateTime? current) {
  return showDatePicker(
    context: context,
    initialDate: current?.toLocal() ?? DateTime.now(),
    firstDate: DateTime(2000),
    lastDate: DateTime(2100),
    builder: (ctx, child) => Theme(
      data: ThemeData.light().copyWith(
        colorScheme: const ColorScheme.light(primary: Color(0xFF2563EB)),
      ),
      child: child!,
    ),
  );
}
