/// Attribute editors shared by the Task Detail screen and the Daily Planning
/// Outcome peek: time estimate, energy and context-tag sheets, and the due-date
/// picker. A behaviour-preserving move out of `task_detail_screen.dart`.
///
/// The sheets report every change through callbacks rather than writing
/// through an Outcome's notifier, so a surface that is not an Outcome — a
/// habit's energy and estimate, say — can offer the same editors.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../models/estimate.dart';
import '../providers/task_detail_provider.dart';
import 'context_tag_picker.dart';
import 'meta_chip.dart';
import 'timeboxed_glyph.dart';

/// Opens the sheet that edits a set of labels: the applied tags and a dotted
/// `+` that opens the searchable tag cloud, or with [cloudOnly] the cloud alone.
///
/// [watchAssignedTags] reads the labels already applied; it runs inside the
/// sheet, so the sheet keeps up with labels applied or removed while it is
/// open. [onAssign] and [onRemove] report every change, and [title] names the
/// sheet for the caller.
void showLabelEditorSheet(
  BuildContext context, {
  required List<Tag> Function(WidgetRef ref) watchAssignedTags,
  required void Function(WidgetRef ref, Tag tag) onAssign,
  required void Function(WidgetRef ref, Tag tag) onRemove,
  String title = 'Edit Labels',
  bool cloudOnly = false,
}) {
  _showLabelSheet(
    context,
    title: title,
    body: (_) => Consumer(
      builder: (context, ref, _) => ContextTagPickerWidget(
        cloudOnly: cloudOnly,
        assignedTags: watchAssignedTags(ref),
        onAssign: (tag) => onAssign(ref, tag),
        onRemove: (tag) => onRemove(ref, tag),
      ),
    ),
  );
}

/// The shell every label sheet shares: a title and its body.
void _showLabelSheet(
  BuildContext context, {
  required String title,
  required Widget Function(BuildContext context) body,
}) {
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
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          body(ctx),
        ],
       ),
      ),
    ),
  );
}

/// Opens the Outcome's labels: [showLabelEditorSheet] over the Outcome's
/// context tags and its notifier.
void showOutcomeContextTagEditor(BuildContext context, String todoId) {
  showLabelEditorSheet(
    context,
    cloudOnly: true,
    watchAssignedTags: (ref) =>
        (ref.watch(taskTagsProvider(todoId)).asData?.value ?? const <Tag>[])
            .where((t) => t.type == 'context')
            .toList(),
    onAssign: (ref, tag) => ref
        .read(taskDetailNotifierProvider(todoId))
        .assignContextTag(tag.id)
        .ignore(),
    onRemove: (ref, tag) => ref
        .read(taskDetailNotifierProvider(todoId))
        .removeContextTag(tag.id)
        .ignore(),
  );
}

/// What the raise sheet has to know about the Action being raised.
///
/// Raising an estimate is a different job from setting one: the value has to
/// beat the time already logged, so the sheet has to say what that time is.
class EstimateRaise {
  const EstimateRaise({
    required this.outcomeTitle,
    required this.limitMinutes,
    required this.logged,
  });

  /// The Outcome the Action belongs to.
  final String outcomeTitle;

  /// The Action's limit as it stands: its estimate.
  final int limitMinutes;

  /// The time logged on the Action so far, breaks included.
  final Duration logged;
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
/// gate's "Raise the estimate…" opens it on the first step above the time
/// logged. Saving writes that value; cancelling writes nothing.
///
/// [raise] puts the sheet in raise mode: it says what has been logged, and
/// will not save a value that does not beat it. Without it the sheet is
/// unchanged for every other caller.
///
/// The sheet does not read the Action's estimate itself. The write path reads
/// the Action's row as it stands, so an estimate a peer cleared while the
/// sheet was open cannot leave the switch with nothing to limit.
///
/// Returns whether the sheet was saved.
///
/// A Habit has no Action and so no Timeboxed switch. It passes
/// [onSaveEstimate] (called with the new minutes, or null to clear) instead of
/// a [notifier], and [showTimeboxedSwitch] false. Exactly one of [notifier] and
/// [onSaveEstimate] is given; Outcome call sites pass the notifier as before.
Future<bool> showOutcomeTimeEstimateSheet(
  BuildContext context,
  TaskDetailNotifier? notifier, {
  required int? current,
  int? initial,
  String? actionText,
  String? actionId,
  bool timeboxed = false,
  bool showTimeboxedSwitch = true,
  Future<void> Function(int? minutes)? onSaveEstimate,
  EstimateRaise? raise,
}) async {
  assert(
    (notifier == null) != (onSaveEstimate == null),
    'Give either a notifier or onSaveEstimate',
  );
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
      showTimeboxedSwitch: showTimeboxedSwitch,
      onSaveEstimate: onSaveEstimate,
      raise: raise,
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
    this.showTimeboxedSwitch = true,
    this.onSaveEstimate,
    this.initial,
    this.actionText,
    this.actionId,
    this.raise,
  });

  final TaskDetailNotifier? notifier;

  /// Saves the estimate when there is no notifier (a Habit); null clears it.
  final Future<void> Function(int? minutes)? onSaveEstimate;

  /// False where there is no Action to limit (a Habit).
  final bool showTimeboxedSwitch;

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

  /// What the raise has to beat, when the sheet is raising rather than
  /// setting; null for every other caller.
  final EstimateRaise? raise;

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

  /// Whether a write is in flight. The sheet cannot be saved twice over.
  bool _saving = false;

  bool get _hasEstimate => _minutes != null;

  /// Whether the ladder has a step above the current value.
  bool get _atTop => _minutes != null && stepEstimateUp(_minutes) == null;

  /// Whether the sheet may be saved.
  ///
  /// A raise has to beat the time already logged: a limit that the work has
  /// already passed is no limit at all. Every other caller may save whatever
  /// the stepper holds.
  bool get _canSave {
    final raise = widget.raise;
    if (raise == null) return true;
    if (_minutes == null) return false;
    return Duration(minutes: _minutes!) > raise.logged;
  }

  void _stepDown() {
    setState(() {
      _minutes = stepEstimateDown(_minutes);
      _stepped = true;
      // No estimate, no limit to mark. A raise keeps the Action Timeboxed
      // whatever the stepper holds, so the switch does not move.
      if (_minutes == null && widget.raise == null) _timeboxed = false;
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
    // One save at a time. A second tap while the first write is still running
    // must not write again, and must not pop a second time: the sheet is on
    // its way out, and a pop takes the top route — which by then may be the
    // screen below it.
    if (_saving || !mounted || !_canSave) return;
    setState(() => _saving = true);
    final notifier = widget.notifier;
    final estimateMoved = _stepped && _minutes != widget.current;
    // A raise keeps the Action Timeboxed: the switch is not on the sheet, so
    // it cannot move, and the write leaves it alone.
    final switchMoved = widget.raise == null &&
        _hasEstimate &&
        _timeboxed != widget.timeboxed;
    try {
      if (notifier == null) {
        if (estimateMoved) await widget.onSaveEstimate!(_minutes);
      } else if (estimateMoved || switchMoved) {
        // One write, so the estimate and the switch land together.
        await notifier.setEstimateAndTimeboxed(
          actionId: widget.actionId ?? '',
          minutes: estimateMoved ? _minutes : null,
          clearEstimate: estimateMoved && _minutes == null,
          timeboxed: switchMoved ? _timeboxed : null,
          // The estimate the sheet shows, for the write that turns the switch
          // on. The limit is measured against the Action's own estimate, so
          // the switch needs one: the write carries this estimate when the
          // Action has none of its own.
          estimateIfUnset: _minutes,
        );
      }
    } catch (_) {
      // The write failed: the sheet stays open and the user can try again.
      if (mounted) setState(() => _saving = false);
      rethrow;
    }
    if (!mounted) return;
    // The sheet's own route: a pop takes the top route, and that may no
    // longer be this sheet.
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final raise = widget.raise;
    Widget body = SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (raise != null) ...[
              Text(
                raise.outcomeTitle,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF4A5568),
                ),
              ),
              const SizedBox(height: 4),
            ],
            Text(
              widget.actionText == null
                  ? 'Estimate'
                  : 'Estimate · ${widget.actionText}',
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold),
            ),
            if (raise != null) ...[
              const SizedBox(height: 8),
              Text(
                'Current limit: ${formatMinutesLabel(raise.limitMinutes)}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF4A5568),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Logged so far: ${formatMinutesLabel(raise.logged.inMinutes)},'
                ' breaks included',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF4A5568),
                ),
              ),
            ],
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
                if (widget.showTimeboxedSwitch && raise == null) ...[
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
              ],
            ),
            if (raise != null) ...[
              const SizedBox(height: 12),
              if (!_canSave)
                // Plain text, not an error: the value is short of the time
                // logged, not wrong.
                Semantics(
                  liveRegion: true,
                  child: Text(
                    'Must be more than the '
                    '${formatMinutesLabel(raise.logged.inMinutes)} already '
                    'logged.',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF4A5568),
                      height: 1.3,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                'I shall re-flow the rest of the day.',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF4A5568),
                  height: 1.3,
                ),
              ),
            ],
            const SizedBox(height: 24),
            // An overflow bar, so the buttons wrap at a large text scale
            // rather than truncating.
            OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: 12,
              children: [
                TextButton(
                  key: const Key('estimate_sheet_cancel'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  key: const Key('estimate_sheet_save'),
                  onPressed: _saving || !_canSave ? null : _save,
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
    if (raise == null) return body;
    // A raise says more than the sheet usually does, and at a large text
    // scale it can be taller than the screen: it scrolls rather than spilling
    // over the edge.
    body = SingleChildScrollView(child: body);
    // The raise sheet names itself for a screen reader: what it is for is not
    // obvious from the controls alone. The sheet's own words stay separate,
    // so the name does not swallow them.
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Raise the estimate for ${widget.actionText ?? ''}',
      child: body,
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
    return Semantics(
      button: true,
      toggled: value,
      enabled: enabled,
      label: enabled
          ? 'Timeboxed: the estimate is a limit. Each sprint past it is '
              'discouraged.'
          : 'Timeboxed: $disabledReason',
      excludeSemantics: true,
      onTap: enabled ? () => onChanged(!value) : null,
      child: Tooltip(
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
      ),
    );
  }
}

/// Opens the energy sheet. [onSet] receives the chosen level, [onClear]
/// removes it.
Future<void> showOutcomeEnergyLevelSheet(
  BuildContext context, {
  required ValueChanged<String> onSet,
  required VoidCallback onClear,
  String? current,
}) async {
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
                  onClear();
                } else {
                  onSet(s.first!);
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
