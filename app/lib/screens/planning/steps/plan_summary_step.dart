library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/focus_session_planning_provider.dart';
import '../../../providers/focus_session_planning_settings_provider.dart';
import '../../../widgets/meta_chip.dart';
import '../../../widgets/outcome_row.dart';
import '../../../widgets/outcome_peek_sheet.dart';

/// Colour of the capacity-bar segment representing minutes counted at the
/// configurable default estimate (selected Outcomes that carry no time
/// estimate). Tailwind blue-300 — the literal "lighter blue" ruled on #463,
/// same family as the Daily Planning accent (`#2563EB`, blue-600).
///
/// NOTE (pending owner decision): the ruling contrasts a "standard tone" with
/// this lighter blue, but the standard tone here is the load-status colour
/// (green/amber/red), never blue — so on amber/red days this segment reads as a
/// distinct hue marking provenance rather than status. The owner may instead
/// prefer a lighter *tint of the current status colour*; that is a one-constant
/// change confined to this value. The literal blue is the ruled default.
const _kDefaultCountedFillColor = Color(0xFF93C5FD);

class PlanSummaryStep extends ConsumerStatefulWidget {
  const PlanSummaryStep({super.key});

  @override
  ConsumerState<PlanSummaryStep> createState() => _PlanSummaryStepState();
}

class _PlanSummaryStepState extends ConsumerState<PlanSummaryStep> {
  final Set<String> _selectedIds = {};
  final TextEditingController _searchController = TextEditingController();

  /// Trimmed, lower-cased search text. Lives in widget state: the query
  /// belongs to this visit of the step.
  String get _query => _searchController.text.trim().toLowerCase();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _matchesQuery(Todo t) => t.title.toLowerCase().contains(_query);

  bool get _selectionMode => _selectedIds.isNotEmpty;

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
    HapticFeedback.selectionClick();
  }

  void _enterSelectionMode(String id) {
    if (_selectedIds.contains(id)) return;
    setState(() => _selectedIds.add(id));
    HapticFeedback.selectionClick();
  }

  void _clearSelection() {
    setState(_selectedIds.clear);
  }

  void _selectAll(List<Todo> pendingTasks) {
    setState(() {
      _selectedIds
        ..clear()
        ..addAll(pendingTasks.map((t) => t.id));
    });
    HapticFeedback.selectionClick();
  }

  void _addSelectedToToday(List<Todo> pendingTasks) {
    final pendingIds = pendingTasks.map((t) => t.id).toSet();
    final notifier = ref.read(focusSessionPlanningProvider.notifier);
    // Filter against the live pending snapshot so a stale id (row deleted
    // between selection and commit) cannot be falsely reported as added.
    final committable = _selectedIds.intersection(pendingIds);
    // Commit in one state publish so the list rebuilds once, not N times.
    notifier.selectTasks(committable.toList());
    setState(_selectedIds.clear);
  }

  @override
  Widget build(BuildContext context) {
    final planningState = ref.watch(focusSessionPlanningProvider);
    final availableMinutes = planningState.availableMinutes;
    final asyncSelected = ref.watch(focusSessionPlanningSelectedTasksProvider);
    final asyncPending = ref.watch(nextForFocusSessionPlanningProvider);
    final asyncSkipped = ref.watch(skippedNextForFocusSessionPlanningProvider);

    // Gate the spinner on "no data yet", not "a reload is in flight". Riverpod
    // retains the previous value while a watched stream re-executes, so after
    // the initial load `hasValue` stays true and this list is never unmounted
    // again — Select, Skip, Undo, and multi-select all reorganise in place
    // instead of flashing a spinner that would reset the scroll offset (#459).
    if (!asyncSelected.hasValue ||
        !asyncPending.hasValue ||
        !asyncSkipped.hasValue) {
      return const Center(child: CircularProgressIndicator());
    }

    final selectedTasks = _sortTasks(asyncSelected.requireValue);
    final pendingTasks = asyncPending.requireValue;
    final skippedTasks = asyncSkipped.requireValue;

    // Estimate-less Outcomes are counted at the configurable default (never
    // written onto the Outcome — this fold is the only place the default lands).
    final defaultEstimate = ref.watch(
      focusSessionPlanningSettingsProvider
          .select((s) => s.defaultTimeEstimate),
    );

    // Split the capacity into real-estimate minutes and default-counted
    // minutes so the bar can render them as two segments. The summary total is
    // their sum, exactly as before.
    final realMinutes = selectedTasks.fold<int>(
        0, (sum, t) => sum + (t.timeEstimate ?? 0));
    final defaultMinutes = selectedTasks
        .where((t) => t.timeEstimate == null)
        .length *
        defaultEstimate;
    final totalMinutes = realMinutes + defaultMinutes;

    final previewMinutes = _selectionMode
        ? pendingTasks
            .where((t) => _selectedIds.contains(t.id))
            .fold<int>(0, (sum, t) => sum + (t.timeEstimate ?? defaultEstimate))
        : 0;

    final searching = _query.isNotEmpty;
    // Watched only while searching, so the default view depends on nothing new.
    final offUpNext = searching
        ? ref
            .watch(offUpNextForFocusSessionPlanningProvider)
            .where((c) => _matchesQuery(c.todo))
            .toList()
        : const <OffUpNextCandidate>[];
    final matchingPending =
        searching ? pendingTasks.where(_matchesQuery).toList() : pendingTasks;
    final matchingSkipped =
        searching ? skippedTasks.where(_matchesQuery).toList() : skippedTasks;

    return Column(
      children: [
        // --- Sticky capacity bar ---
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionLabel('Capacity'),
              const SizedBox(height: 8),
              _CapacityBar(
                realMinutes: realMinutes,
                defaultMinutes: defaultMinutes,
                availableMinutes: availableMinutes,
              ),
              const SizedBox(height: 6),
              Text(
                _capacitySummary(
                    selectedTasks.length, totalMinutes, availableMinutes),
                style: TextStyle(fontSize: 13, color: Colors.grey[600]),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFFF3F4F6)),

        _SearchField(
          controller: _searchController,
          enabled: !_selectionMode,
          onChanged: (_) => setState(() {}),
          onClear: () => setState(_searchController.clear),
        ),

        if (_selectionMode)
          _MultiSelectActionBar(
            selectedCount: _selectedIds.length,
            pendingCount: pendingTasks.length,
            previewMinutes: previewMinutes,
            onClear: _clearSelection,
            onSelectAll:
                pendingTasks.isEmpty ? null : () => _selectAll(pendingTasks),
            onAddToToday: () => _addSelectedToToday(pendingTasks),
          ),

        // --- Scrollable task list ---
        Expanded(
          child: ScrollConfiguration(
            // Disable the M3 stretch (and legacy glow) overscroll indicator.
            // ClampingScrollPhysics already clamps the scroll position, but it
            // still dispatches an OverscrollNotification that would trigger the
            // StretchingOverscrollIndicator unless we opt out here.
            behavior:
                ScrollConfiguration.of(context).copyWith(overscroll: false),
            child: ListView(
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                if (searching)
                  ..._searchResults(
                    matchingPending,
                    matchingSkipped,
                    offUpNext,
                  ),

                // Today's tasks (selected)
                if (!searching && selectedTasks.isNotEmpty) ...[
                  _SectionLabel('Today\'s Plan (${selectedTasks.length})'),
                  const SizedBox(height: 8),
                  ...selectedTasks.map((t) => _planOutcomeRow(
                        todo: t,
                        isSelected: true,
                        onUndo: () => _handleUndo(t),
                        onSkip: () => _handleSkip(t),
                        onPeek: _selectionMode
                            ? null
                            : () => OutcomePeekSheet.show(context, t),
                      )),
                  const SizedBox(height: 16),
                ],

                // Up Next — the undecided pool
                if (!searching && pendingTasks.isNotEmpty) ...[
                  _SectionLabel('Up Next (${pendingTasks.length})'),
                  const SizedBox(height: 8),
                  ...pendingTasks.map((t) => _planOutcomeRow(
                        todo: t,
                        onSelect: () => _handleSelect(t),
                        onSkip: () => _handleSkip(t),
                        selectionMode: _selectionMode,
                        isChecked: _selectedIds.contains(t.id),
                        onLongPress: () => _enterSelectionMode(t.id),
                        onTapInSelectionMode: () => _toggleSelection(t.id),
                        onPeek: _selectionMode
                            ? null
                            : () => OutcomePeekSheet.show(context, t),
                      )),
                  const SizedBox(height: 16),
                ],

                // Skipped
                if (!searching && skippedTasks.isNotEmpty) ...[
                  _SectionLabel('Skipped (${skippedTasks.length})'),
                  const SizedBox(height: 8),
                  ...skippedTasks.map((t) => _planOutcomeRow(
                        todo: t,
                        isSkipped: true,
                        onSelect: () => _handleSelect(t),
                        onUndo: () => _handleUndo(t),
                        onPeek: _selectionMode
                            ? null
                            : () => OutcomePeekSheet.show(context, t),
                      )),
                ],

                if (!searching &&
                    selectedTasks.isEmpty &&
                    pendingTasks.isEmpty &&
                    skippedTasks.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      'Nothing to plan.',
                      style: TextStyle(fontSize: 14, color: Colors.grey[400]),
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// The list while a search is active: Up Next matches (then Skipped
  /// matches), then the visually separate group from outside Up Next. Rows
  /// carry Select and peek only — no long-press, so no multi-select here.
  List<Widget> _searchResults(
    List<Todo> pending,
    List<Todo> skipped,
    List<OffUpNextCandidate> offUpNext,
  ) {
    final upNextCount = pending.length + skipped.length;
    return [
      if (upNextCount > 0) ...[
        _SectionLabel('Up Next ($upNextCount)'),
        const SizedBox(height: 8),
        ...pending.map((t) => _planOutcomeRow(
              todo: t,
              onSelect: () => _handleSelect(t),
              onSkip: () => _handleSkip(t),
              onPeek: () => OutcomePeekSheet.show(context, t),
            )),
        ...skipped.map((t) => _planOutcomeRow(
              todo: t,
              isSkipped: true,
              onSelect: () => _handleSelect(t),
              onUndo: () => _handleUndo(t),
              onPeek: () => OutcomePeekSheet.show(context, t),
            )),
        const SizedBox(height: 16),
      ],
      if (offUpNext.isNotEmpty) ...[
        _SectionLabel('Not in Up Next (${offUpNext.length})'),
        const SizedBox(height: 8),
        ...offUpNext.map((c) => _planOutcomeRow(
              todo: c.todo,
              offUpNextReason: c.reason,
              onSelect: () => _handleSelect(c.todo),
              onPeek: () => OutcomePeekSheet.show(context, c.todo),
            )),
      ],
      if (upNextCount == 0 && offUpNext.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(
            'No matches.',
            style: TextStyle(fontSize: 14, color: Colors.grey[400]),
            textAlign: TextAlign.center,
          ),
        ),
    ];
  }

  void _handleSelect(Todo todo) {
    ref.read(focusSessionPlanningProvider.notifier).selectTask(todo.id);
  }

  void _handleSkip(Todo todo) {
    ref.read(focusSessionPlanningProvider.notifier).skipTask(todo.id);
  }

  void _handleUndo(Todo todo) {
    ref.read(focusSessionPlanningProvider.notifier).undoTaskReview(todo.id);
  }

  List<Todo> _sortTasks(List<Todo> tasks) {
    final withDue = tasks.where((t) => t.dueDate != null).toList()
      ..sort((a, b) => a.dueDate!.compareTo(b.dueDate!));
    final noDue = tasks.where((t) => t.dueDate == null).toList();
    return [...withDue, ...noDue];
  }

  String _capacitySummary(int count, int totalMinutes, int availableMinutes) {
    final planned = formatMinutesLabel(totalMinutes);
    final available = formatMinutesLabel(availableMinutes);
    return '$count task${count == 1 ? '' : 's'} · $planned planned of $available available';
  }
}

// ---------------------------------------------------------------------------
// Widgets
// ---------------------------------------------------------------------------

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.2,
        color: Color(0xFF9CA3AF),
      ),
    );
  }
}

/// Capacity progress bar with a two-tone fill.
///
/// Real-estimate minutes render in the load-status tone (green ≤ 0.8, amber
/// ≤ 1.0, red over — keyed off the *combined* ratio so the warn/over
/// thresholds are unchanged), and default-counted minutes render as a lighter
/// blue segment ([_kDefaultCountedFillColor]) laid immediately after them. When
/// there are no default-counted minutes the bar is pixel-identical to a single
/// status-tone fill over the track. `LinearProgressIndicator` cannot paint two
/// segments, so the fill is drawn directly while the geometry — 10px height,
/// 4px clip, `#E5E7EB` track — is preserved exactly.
class _CapacityBar extends StatelessWidget {
  const _CapacityBar({
    required this.realMinutes,
    required this.defaultMinutes,
    required this.availableMinutes,
  });

  final int realMinutes;
  final int defaultMinutes;
  final int availableMinutes;

  @override
  Widget build(BuildContext context) {
    final combinedRatio = availableMinutes > 0
        ? (realMinutes + defaultMinutes) / availableMinutes
        : double.infinity;

    final Color statusColor;
    if (combinedRatio <= 0.8) {
      statusColor = const Color(0xFF16A34A);
    } else if (combinedRatio <= 1.0) {
      statusColor = const Color(0xFFF59E0B);
    } else {
      statusColor = const Color(0xFFDC2626);
    }

    // Fractional widths within the track. The real segment takes precedence;
    // the default segment fills whatever remains up to a full bar.
    double fraction(int minutes) => availableMinutes > 0
        ? minutes / availableMinutes
        : (minutes > 0 ? 1.0 : 0.0);
    final realFraction = fraction(realMinutes).clamp(0.0, 1.0);
    final defaultFraction =
        fraction(defaultMinutes).clamp(0.0, 1.0 - realFraction);

    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 10,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return Stack(
              children: [
                const Positioned.fill(
                  child: ColoredBox(color: Color(0xFFE5E7EB)),
                ),
                Row(
                  children: [
                    Container(
                      key: const Key('capacity_real_segment'),
                      width: width * realFraction,
                      color: statusColor,
                    ),
                    if (defaultFraction > 0)
                      Container(
                        key: const Key('capacity_default_segment'),
                        width: width * defaultFraction,
                        color: _kDefaultCountedFillColor,
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Contextual bar shown above the Up Next list while multi-select is
/// active. Sits inside the step (not the screen-level app bar, which is owned
/// by [FocusSessionPlanningScreen] and renders step progress).
class _MultiSelectActionBar extends StatelessWidget {
  const _MultiSelectActionBar({
    required this.selectedCount,
    required this.pendingCount,
    required this.previewMinutes,
    required this.onClear,
    required this.onSelectAll,
    required this.onAddToToday,
  });

  final int selectedCount;
  final int pendingCount;
  final int previewMinutes;
  final VoidCallback onClear;
  final VoidCallback? onSelectAll;
  final VoidCallback onAddToToday;

  @override
  Widget build(BuildContext context) {
    final allSelected = selectedCount >= pendingCount && pendingCount > 0;
    return Semantics(
      label: '$selectedCount task${selectedCount == 1 ? '' : 's'} selected',
      container: true,
      child: Material(
        color: const Color(0xFFEFF6FF),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          child: Row(
            children: [
              Tooltip(
                message: 'Clear selection',
                child: IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  color: const Color(0xFF374151),
                  onPressed: onClear,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$selectedCount selected',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                    if (previewMinutes > 0)
                      Text(
                        '+${formatMinutesLabel(previewMinutes)} planned',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[600],
                        ),
                      ),
                  ],
                ),
              ),
              if (onSelectAll != null && !allSelected)
                TextButton(
                  onPressed: onSelectAll,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF2563EB),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Select all'),
                ),
              const SizedBox(width: 4),
              Tooltip(
                message:
                    'Add $selectedCount task${selectedCount == 1 ? '' : 's'} to today\'s plan',
                child: FilledButton(
                  onPressed: onAddToToday,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    minimumSize: Size.zero,
                  ),
                  child: const Text('Add to Today'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Card representing a task in the plan-summary review list.
///
/// Two buttons are always shown in fixed positions so the layout never shifts:
/// - **Left slot** — the "select" action or its undo:
///   - pending & skipped → Select (check icon)
///   - selected → Undo (un-select)
/// - **Right slot** — the "skip" action or its undo:
///   - pending & selected → Skip (minus icon)
///   - skipped → Undo (un-skip)
///
/// This means "only the button that was pressed changes to Undo".
///
/// When [selectionMode] is true, the trailing icon slot is hidden and a
/// leading checkbox is shown instead; the whole card responds to taps via
/// [onTapInSelectionMode]. [onLongPress] is the entry point into selection
/// mode and is only meaningful on Up Next rows.
///
/// [onPeek] — a plain tap outside selection mode opens the editable Outcome
/// peek sheet. Callers pass `null` while multi-select is active so the card
/// carries no gesture params in-mode: on Today's Plan / Skipped rows that
/// leaves the row without a gesture handler (tap inert, rendering and
/// the trailing action buttons untouched); Pending rows keep their in-mode
/// checkbox-toggle wiring. This is why the peek is gated at the call site
/// rather than by threading [selectionMode] here — [selectionMode] stays purely
/// a Pending-card rendering flag.
Widget _planOutcomeRow({
  required Todo todo,
  bool isSelected = false,
  bool isSkipped = false,
  VoidCallback? onSelect,
  VoidCallback? onSkip,
  VoidCallback? onUndo,
  bool selectionMode = false,
  bool isChecked = false,
  VoidCallback? onLongPress,
  VoidCallback? onTapInSelectionMode,
  VoidCallback? onPeek,
  OffUpNextReason? offUpNextReason,
}) {
  return OutcomeRow(
    title: todo.title,
    framed: true,
    muted: isSkipped,
    backgroundColor: isSkipped || offUpNextReason != null
        ? const Color(0xFFF9FAFB)
        : Colors.white,
    borderColor: isSkipped ? const Color(0xFFF3F4F6) : const Color(0xFFE5E7EB),
    onTap: selectionMode ? onTapInSelectionMode : onPeek,
    onLongPress: onLongPress,
    leading: selectionMode
        ? Tooltip(
            message: 'Select',
            child: Checkbox(
              value: isChecked,
              onChanged: onTapInSelectionMode == null
                  ? null
                  : (_) => onTapInSelectionMode(),
              visualDensity: VisualDensity.compact,
            ),
          )
        : null,
    meta: Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (offUpNextReason != null)
          MetaChip(
            icon: Icons.inbox_outlined,
            label: offUpNextReason.label,
            color: const Color(0xFF6B7280),
          ),
        OutcomeMetaLine(
          energyLevel: todo.energyLevel,
          timeEstimateMinutes: todo.timeEstimate,
        ),
      ],
    ),
    trailing: selectionMode
        ? const SizedBox.shrink()
        : SizedBox(
            width: 80,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // Left slot: Select (pending/skipped) or Undo-of-select (planned)
                if (isSelected && onUndo != null)
                  _IconBtn(
                    icon: Icons.undo,
                    color: const Color(0xFF6B7280),
                    tooltip: 'Remove from today',
                    onTap: onUndo,
                  )
                else if (!isSelected && onSelect != null)
                  _IconBtn(
                    icon: Icons.check_circle_outline,
                    color: const Color(0xFF16A34A),
                    tooltip: 'Select for today',
                    onTap: onSelect,
                  ),
                // Right slot: Skip (pending/planned) or Undo-of-skip (skipped)
                if (isSkipped && onUndo != null)
                  _IconBtn(
                    icon: Icons.undo,
                    color: const Color(0xFF6B7280),
                    tooltip: 'Un-skip',
                    onTap: onUndo,
                  )
                else if (!isSkipped && onSkip != null)
                  _IconBtn(
                    icon: Icons.remove_circle_outline,
                    color: const Color(0xFF6B7280),
                    tooltip: 'Skip for today',
                    onTap: onSkip,
                  ),
              ],
            ),
          ),
  );
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.enabled,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: TextField(
        controller: controller,
        enabled: enabled,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search tasks',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear, size: 20),
                  tooltip: 'Clear search',
                  onPressed: enabled ? onClear : null,
                ),
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Use InkWell + Padding instead of IconButton to avoid M3's 48px minimum
    // touch-target enforcement, which caused overflow in the fixed-width button
    // slot (2 × 48px = 96px > 80px SizedBox).
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, color: color, size: 22),
        ),
      ),
    );
  }
}
