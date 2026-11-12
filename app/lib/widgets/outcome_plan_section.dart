import 'package:flutter/material.dart' hide Action;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../models/action_draft.dart';
import '../providers/task_detail_provider.dart';
import 'clarify_shared_widgets.dart';
import 'meta_chip.dart';
import 'replace_current_action_sheet.dart';

/// The Outcome's **Plan** (ADR-0004 story 5, issue #475): the current Action as
/// an anchor row (with a demote affordance), the ordered planned queue, and an
/// inline add affordance. Planned Actions are only ever shown here — they are
/// not engageable (CONTEXT.md § Action).
///
/// Promotion is an explicit clarifying act: with no current Action the up-arrow
/// promotes directly; with a current Action it opens the "Replace current
/// action" confirm sheet (supersede-and-promote), never a silent replace. No
/// SnackBars — every affordance is inline, per the screen's idiom.
class OutcomePlanSection extends ConsumerStatefulWidget {
  const OutcomePlanSection({super.key, required this.outcomeId});

  final String outcomeId;

  @override
  ConsumerState<OutcomePlanSection> createState() => _OutcomePlanSectionState();
}

class _OutcomePlanSectionState extends ConsumerState<OutcomePlanSection> {
  static const _muted = Color(0xFF9CA3AF);
  static const _ink = Color(0xFF1F2937);
  static const _energyColor = Color(0xFF7C3AED);
  static const _timeColor = Color(0xFF2563EB);

  TaskDetailNotifier get _notifier =>
      ref.read(taskDetailNotifierProvider(widget.outcomeId));

  /// Opens the add/edit sheet for a planned Action — [row] null to add one.
  ///
  /// Dismissing the sheet cancels silently, matching [_confirmReplace] and
  /// [_confirmAbandon]: one confirm button, no Cancel, barrier tap discards.
  ///
  /// Takes the **row**, never its index. A planned row's index moves under a
  /// drag or a synced reorder, and closing over it would send the edit to
  /// whichever Action happened to land in that slot. The row's `id` is stable.
  Future<void> _openActionSheet({Action? row}) async {
    // Captured before the await: reading the autoDispose provider afterwards
    // can outlive the ref.
    final notifier = _notifier;
    final result = await showModalBottomSheet<ActionDraft>(
      context: context,
      backgroundColor: Colors.white,
      // Carries a text field, so the sheet must be able to grow past half the
      // screen and sit above the keyboard.
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
      ),
      builder: (ctx) => _PlanActionSheet(initial: row),
    );
    if (result == null) return; // dismissed → cancel
    if (row == null) {
      notifier.addPlannedAction(result).ignore();
    } else {
      notifier.editAction(row.id, result).ignore();
    }
  }

  void _onPromote(Action row, Action? current) {
    if (current == null) {
      _notifier.promotePlannedAction(row.id).ignore();
    } else {
      _confirmReplace(current: current, planned: row);
    }
  }

  Future<void> _confirmReplace({
    required Action current,
    required Action planned,
  }) async {
    // Captured before the await: reading the autoDispose provider afterwards
    // can outlive the ref if the detail State unmounts while the sheet is open
    // (same reason as [_openActionSheet]).
    final notifier = _notifier;
    // The shared confirm returns the verdict; this surface keeps its inline,
    // no-snackbar write idiom (`.ignore()`), unlike the re-clarify surfaces
    // which await the write inside a boundary (see [showReplaceCurrentActionSheet]).
    final confirmed = await showReplaceCurrentActionSheet(
      context,
      currentText: current.actionText,
      newText: planned.actionText,
    );
    if (confirmed) {
      // Pass the id of the current Action the confirm showed, so the write
      // aborts rather than retire a different one if sync swapped the current
      // while the sheet was open (#723). The reactive Plan section then shows
      // the true state; the `.ignore()` keeps this surface's no-snackbar idiom.
      notifier
          .supersedeAndPromote(planned.id, expectedCurrentActionId: current.id)
          .ignore();
    }
  }

  Widget _sheetLine(String label, String text, Color color) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
              color: _muted,
            ),
          ),
          const SizedBox(height: 2),
          Text(text, style: TextStyle(fontSize: 15, color: color)),
        ],
      );

  @override
  Widget build(BuildContext context) {
    // AsyncValue.value retains the last data across a transient loading/error
    // (Riverpod stream refresh/re-subscribe), where .asData?.value would go
    // null. Keeping the Plan visible matters, and the retained `current` keeps
    // the promote decision routing through the 'Replace current action' confirm
    // instead of mis-firing a direct promote.
    final current = ref.watch(currentActionProvider(widget.outcomeId)).value;
    final planned =
        ref.watch(plannedActionsProvider(widget.outcomeId)).value ??
            const <Action>[];

    return Padding(
      key: const Key('plan_section'),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.checklist_rounded, size: 16, color: _muted),
              const SizedBox(width: 8),
              const Text(
                'PLAN',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  color: _muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildCurrentRow(current),
          if (planned.isNotEmpty) ...[
            const SizedBox(height: 4),
            _buildPlannedQueue(planned, current),
          ] else if (current == null) ...[
            const SizedBox(height: 8),
            const Text(
              "No plan yet — add the actions you're thinking of.",
              style: TextStyle(fontSize: 14, color: Color(0xFFD1D5DB)),
            ),
          ],
          const SizedBox(height: 8),
          _buildAddAffordance(),
        ],
      ),
    );
  }

  Widget _buildCurrentRow(Action? current) {
    if (current == null) {
      return const Padding(
        key: Key('plan_current_action'),
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'No current action',
          style: TextStyle(fontSize: 15, color: _muted),
        ),
      );
    }
    return Container(
      key: const Key('plan_current_action'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.radio_button_checked, size: 18,
              color: Color(0xFF2563EB)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              current.actionText,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: _ink,
              ),
            ),
          ),
          IconButton(
            key: const Key('plan_demote_button'),
            icon: const Icon(Icons.arrow_downward, size: 18, color: _muted),
            tooltip: 'Move to plan',
            visualDensity: VisualDensity.compact,
            onPressed: () => _notifier.demoteCurrentAction(current.id).ignore(),
          ),
          // Abandon (issue #478): retire the current Action into history with
          // no replacement. Deliberately *not* the planned row's × — that one
          // hard-deletes an unengaged note, this one files an engaged Action
          // into the Outcome's record. Only rendered when a current exists.
          IconButton(
            key: const Key('plan_abandon_button'),
            icon: const Icon(Icons.archive_outlined, size: 18, color: _muted),
            tooltip: 'Abandon',
            visualDensity: VisualDensity.compact,
            onPressed: () => _confirmAbandon(current),
          ),
        ],
      ),
    );
  }

  /// Abandoning is irreversible — a terminated Action is a record with no
  /// un-abandon — so it goes through the same confirm-sheet idiom as
  /// "Replace current action", never a bare tap.
  Future<void> _confirmAbandon(Action current) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Abandon this action?',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              _sheetLine('Current', current.actionText, _ink),
              const SizedBox(height: 8),
              const Text(
                'It moves into this outcome\'s history. Nothing takes its '
                'place — the outcome is left without a current action.',
                style: TextStyle(fontSize: 13, color: _muted),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('plan_abandon_confirm'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                  ),
                  onPressed: () {
                    _notifier.abandonCurrentAction().ignore();
                    Navigator.pop(ctx);
                  },
                  child: const Text('Abandon'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlannedQueue(List<Action> planned, Action? current) {
    return ReorderableListView(
      shrinkWrap: true,
      buildDefaultDragHandles: false,
      physics: const NeverScrollableScrollPhysics(),
      // onReorderItem already accounts for the removed item, so no manual
      // `newIndex -= 1` adjustment (unlike the deprecated onReorder).
      onReorderItem: (oldIndex, newIndex) {
        final ids = planned.map((a) => a.id).toList();
        final moved = ids.removeAt(oldIndex);
        ids.insert(newIndex, moved);
        _notifier.reorderPlannedActions(ids).ignore();
      },
      children: [
        for (var i = 0; i < planned.length; i++)
          _buildPlannedRow(planned[i], i, current),
      ],
    );
  }

  Widget _buildPlannedRow(Action row, int index, Action? current) {
    return Padding(
      key: Key('planned_action_${row.id}'),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          // `index` is used here and nowhere else in this row: it belongs to
          // the drag system's index space, and the tap target below sits
          // outside this listener's subtree so nothing else can enter it.
          ReorderableDragStartListener(
            index: index,
            child: const Padding(
              key: Key('plan_drag_handle'),
              padding: EdgeInsets.only(right: 8),
              child: Icon(Icons.drag_indicator, size: 18, color: _muted),
            ),
          ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _openActionSheet(row: row),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      row.actionText,
                      style: const TextStyle(fontSize: 15, color: _ink),
                    ),
                    const SizedBox(height: 2),
                    _buildEffortMeta(row),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            key: Key('plan_promote_${row.id}'),
            icon: const Icon(Icons.arrow_upward, size: 18, color: _muted),
            tooltip: 'Make current',
            visualDensity: VisualDensity.compact,
            onPressed: () => _onPromote(row, current),
          ),
          IconButton(
            key: Key('plan_remove_${row.id}'),
            icon: const Icon(Icons.close, size: 18, color: _muted),
            tooltip: 'Remove',
            visualDensity: VisualDensity.compact,
            onPressed: () => _notifier.removePlannedAction(row.id).ignore(),
          ),
        ],
      ),
    );
  }

  /// The planned row's effort line: an energy chip, a time chip, or — when the
  /// row carries neither — a quiet `Set` prompt.
  ///
  /// **Read-only by construction.** [MetaChip] contains no gesture, and the
  /// `Set` prompt is bare `Text`; the row's single tap target is the ancestor
  /// [GestureDetector] that opens the sheet, so there is exactly one way in.
  Widget _buildEffortMeta(Action row) {
    final energy = row.energyLevel;
    final time = row.timeEstimate;
    if (energy == null && time == null) {
      return Text(
        'Set',
        key: Key('planned_effort_unset_${row.id}'),
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: _muted,
        ),
      );
    }
    return Wrap(
      key: Key('planned_meta_${row.id}'),
      spacing: 8,
      runSpacing: 4,
      children: [
        if (energy != null)
          MetaChip(
            key: Key('planned_energy_${row.id}'),
            icon: Icons.bolt_outlined,
            label: energyLevelLabel(energy),
            color: _energyColor,
          ),
        if (time != null)
          MetaChip(
            key: Key('planned_time_${row.id}'),
            icon: Icons.timer_outlined,
            label: formatMinutesLabel(time),
            color: _timeColor,
          ),
      ],
    );
  }

  Widget _buildAddAffordance() {
    return InkWell(
      key: const Key('plan_add_trigger'),
      onTap: () => _openActionSheet(),
      borderRadius: BorderRadius.circular(4),
      child: const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(Icons.add, size: 18, color: Color(0xFF2563EB)),
            SizedBox(width: 8),
            // The label takes the leftover width and truncates to one line with
            // an ellipsis: at 320dp a long localisation of this phrase has
            // nowhere to go beside the fixed-width icon, and a wrapped label
            // would push the affordance taller than the rows it sits under.
            Flexible(
              child: Text(
                'Add planned action',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF2563EB),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The add/edit sheet for a planned Action: the phrase plus the two effort
/// pickers, returning an [ActionDraft] on confirm and null on dismissal.
///
/// One widget, one parameter: [initial] null adds, non-null edits. The pickers
/// are the same [ClarifyEnergyPicker] / [ClarifyEstimateChip] the clarify
/// surfaces use, over the same [kEstimateOptionsMinutes] ladder, so effort
/// means the same thing wherever it is set.
///
/// **An empty title cannot delete the row.** In edit mode a blank field just
/// parks the sheet un-confirmable; dismissing discards the edit and the row
/// keeps the text it had. Removing a planned Action is the row's `×` and
/// nothing else.
class _PlanActionSheet extends StatefulWidget {
  const _PlanActionSheet({this.initial});

  /// The Action being edited, or null when adding a new one.
  final Action? initial;

  @override
  State<_PlanActionSheet> createState() => _PlanActionSheetState();
}

class _PlanActionSheetState extends State<_PlanActionSheet> {
  late final TextEditingController _textController;
  String? _energyLevel;
  int? _timeEstimateMinutes;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.initial?.actionText);
    _energyLevel = widget.initial?.energyLevel;
    _timeEstimateMinutes = widget.initial?.timeEstimate;
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  bool get _canConfirm => _textController.text.trim().isNotEmpty;

  void _confirm() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    Navigator.pop(
      context,
      ActionDraft(
        text: text,
        energyLevel: _energyLevel,
        timeEstimateMinutes: _timeEstimateMinutes,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.initial != null;
    return SafeArea(
      child: Padding(
        // The keyboard inset is what keeps the field and confirm button off
        // the top of the keyboard on a short screen.
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                editing ? 'Edit planned action' : 'Add planned action',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('plan_action_text'),
                controller: _textController,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                minLines: 1,
                maxLines: 2,
                style: const TextStyle(fontSize: 15),
                decoration: const InputDecoration(
                  labelText: 'Action',
                  hintText: "What's the next physical, visible step?",
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(4)),
                  ),
                ),
                // Rebuild so the confirm button's enablement tracks the field.
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _confirm(),
              ),
              const SizedBox(height: 20),
              const ClarifyFieldLabel('ENERGY LEVEL'),
              const SizedBox(height: 8),
              ClarifyEnergyPicker(
                key: const Key('plan_action_energy'),
                selected: _energyLevel,
                onSelect: (value) => setState(() => _energyLevel = value),
              ),
              const SizedBox(height: 20),
              const ClarifyFieldLabel('TIME ESTIMATE'),
              const SizedBox(height: 8),
              ClarifyEstimatePicker(
                key: const Key('plan_action_estimate'),
                selectedMinutes: _timeEstimateMinutes,
                onSelect: (minutes) => setState(() => _timeEstimateMinutes = minutes),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('plan_action_confirm'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(2)),
                    ),
                  ),
                  onPressed: _canConfirm ? _confirm : null,
                  child: Text(editing ? 'Save' : 'Add'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
