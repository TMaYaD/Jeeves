/// Step 0 of the daily planning ritual: Clarify Inbox.
///
/// Works through each inbox item one at a time:
/// 1. Prompts the user to clarify the expected outcome (editable title/notes).
/// 2. Lets the user set energy level, time estimate, and due date.
/// 3. Routes the item to the correct GTD list (Next Action, Waiting For,
///    Someday/Maybe, Scheduled, or Done).
///
/// The Next button in the parent is enabled only when the inbox is empty.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/daily_planning_provider.dart';
import '../../../providers/inbox_provider.dart';

class InboxClarificationStep extends ConsumerWidget {
  const InboxClarificationStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncItems = ref.watch(inboxItemsProvider);
    final sessionDate = ref.watch(planningSessionDateProvider);

    return asyncItems.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Error: $err')),
      data: (items) {
        final pendingItems = items.where((i) => !(i.selectedForToday == false && i.dailySelectionDate == sessionDate)).toList();

        WidgetsBinding.instance.addPostFrameCallback((_) {
          final state = ref.read(dailyPlanningProvider);
          if (state.initialInboxCount == null) {
            ref.read(dailyPlanningProvider.notifier).setInitialInboxCount(pendingItems.length);
          }
        });

        if (pendingItems.isEmpty) {
          return const _InboxCleared();
        }
        // Show remaining count + the first (oldest-last) item to clarify.
        // inboxItemsProvider orders by createdAt DESC so items.last is oldest.
        // Process in FIFO order: work from the end of the list forward.
        final current = pendingItems.last;
        return _ClarifyCard(
          key: ValueKey(current.id),
          todo: current,
          remaining: pendingItems.length,
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Per-item clarification card
// ---------------------------------------------------------------------------

class _ClarifyCard extends ConsumerStatefulWidget {
  const _ClarifyCard({
    super.key,
    required this.todo,
    required this.remaining,
  });

  final Todo todo;
  final int remaining;

  @override
  ConsumerState<_ClarifyCard> createState() => _ClarifyCardState();
}

class _ClarifyCardState extends ConsumerState<_ClarifyCard> {
  late TextEditingController _titleCtrl;
  late TextEditingController _notesCtrl;
  String? _energyLevel;
  int? _timeEstimate;
  DateTime? _dueDate;

  static const _estimateOptions = [5, 10, 15, 30, 45, 60, 90, 120];

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.todo.title);
    _notesCtrl = TextEditingController(text: widget.todo.notes ?? '');
    _energyLevel = widget.todo.energyLevel;
    _timeEstimate = widget.todo.timeEstimate;
    _dueDate = widget.todo.dueDate;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  /// Validates and saves editable fields on the current inbox item.
  ///
  /// Returns `false` (and shows a validation error) if the title is empty,
  /// since a task must have a non-empty title before it can be processed.
  Future<bool> _saveFields(BuildContext context) async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      return false;
    }
    final notes = _notesCtrl.text.trim();
    await ref.read(dailyPlanningProvider.notifier).updateInboxItemFields(
          widget.todo.id,
          title: title,
          notes: notes.isNotEmpty ? notes : null,
          energyLevel: _energyLevel,
          timeEstimate: _timeEstimate,
          dueDate: _dueDate,
          clearDueDate: _dueDate == null && widget.todo.dueDate != null,
        );
    return true;
  }

  Future<void> _process(BuildContext context, GtdState destination) async {
    // Scheduled requires a due date.
    if (destination == GtdState.scheduled && _dueDate == null) {
      final picked = await _pickDate(context);
      if (picked == null) return; // user cancelled — stay on card
      if (!context.mounted) return;
      setState(() => _dueDate = picked);
    }

    Object? error;
    try {
      final saved = await _saveFields(context);
      if (!saved || !context.mounted) return;
      await ref
          .read(dailyPlanningProvider.notifier)
          .processInboxItem(widget.todo.id, destination);
    } catch (e) {
      error = e;
    }

    if (!context.mounted) return;
    if (error != null) {
      debugPrint('Error: $error');
    }
  }

  Future<DateTime?> _pickDate(BuildContext context) {
    final now = DateTime.now();
    return showDatePicker(
      context: context,
      initialDate: _dueDate ?? now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'Set due date',
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        // Progress indicator
        Text(
          '${widget.remaining} item${widget.remaining == 1 ? '' : 's'} remaining',
          style: TextStyle(fontSize: 13, color: Colors.grey[500]),
        ),
        const SizedBox(height: 12),

        // Clarifying question prompt
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFEFF6FF),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFDBEAFE)),
          ),
          child: Row(
            children: [
              const Icon(Icons.help_outline,
                  size: 18, color: Color(0xFF2563EB)),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'What\'s the expected outcome?',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1D4ED8),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Title
        TextField(
          controller: _titleCtrl,
          decoration: InputDecoration(
            labelText: 'Title',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          textCapitalization: TextCapitalization.sentences,
          maxLines: 2,
          minLines: 1,
        ),
        const SizedBox(height: 12),

        // Notes
        TextField(
          controller: _notesCtrl,
          decoration: InputDecoration(
            labelText: 'Notes (optional)',
            hintText: 'Context, desired outcome, dependencies…',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          textCapitalization: TextCapitalization.sentences,
          maxLines: 4,
          minLines: 2,
        ),
        const SizedBox(height: 20),

        // Energy level
        _FieldLabel('ENERGY LEVEL'),
        const SizedBox(height: 8),
        _EnergyPicker(
          selected: _energyLevel,
          onSelect: (level) => setState(() => _energyLevel = level),
        ),
        const SizedBox(height: 20),

        // Time estimate
        _FieldLabel('TIME ESTIMATE'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _estimateOptions.map((m) {
            final selected = _timeEstimate == m;
            return _EstimateChip(
              label: m < 60
                  ? '${m}m'
                  : m % 60 == 0
                      ? '${m ~/ 60}h'
                      : '${m ~/ 60}h ${m % 60}m',
              selected: selected,
              onTap: () => setState(
                  () => _timeEstimate = selected ? null : m),
            );
          }).toList(),
        ),
        const SizedBox(height: 20),

        // Due date
        _FieldLabel('DUE DATE'),
        const SizedBox(height: 8),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: () async {
                final picked = await _pickDate(context);
                if (picked != null && context.mounted) {
                  setState(() => _dueDate = picked);
                }
              },
              icon: const Icon(Icons.calendar_today_outlined, size: 16),
              label: Text(
                _dueDate != null
                    ? '${_dueDate!.year}-'
                        '${_dueDate!.month.toString().padLeft(2, '0')}-'
                        '${_dueDate!.day.toString().padLeft(2, '0')}'
                    : 'Set date',
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: _dueDate != null
                    ? const Color(0xFF2563EB)
                    : const Color(0xFF6B7280),
              ),
            ),
            if (_dueDate != null) ...[
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                color: Colors.grey[400],
                tooltip: 'Clear date',
                onPressed: () => setState(() => _dueDate = null),
              ),
            ],
          ],
        ),
        const SizedBox(height: 28),

        // Destination buttons
        _FieldLabel('PROCESS TO'),
        const SizedBox(height: 12),
        _DestinationButton(
          label: 'Next Action',
          icon: Icons.check_circle_outline,
          color: const Color(0xFF16A34A),
          onTap: () => _process(context, GtdState.nextAction),
        ),
        const SizedBox(height: 8),
        _DestinationButton(
          label: 'Scheduled',
          icon: Icons.event_outlined,
          color: const Color(0xFF2563EB),
          onTap: () => _process(context, GtdState.scheduled),
        ),
        const SizedBox(height: 8),
        _DestinationButton(
          label: 'Waiting For',
          icon: Icons.hourglass_empty,
          color: const Color(0xFFF59E0B),
          onTap: () => _process(context, GtdState.waitingFor),
        ),
        const SizedBox(height: 8),
        _DestinationButton(
          label: 'Someday / Maybe',
          icon: Icons.star_border,
          color: const Color(0xFF6B7280),
          onTap: () => _process(context, GtdState.somedayMaybe),
        ),
        const SizedBox(height: 8),
        _DestinationButton(
          label: 'Done (discard)',
          icon: Icons.delete_outline,
          color: const Color(0xFFDC2626),
          onTap: () => _process(context, GtdState.done),
        ),
        const SizedBox(height: 20),
        _DestinationButton(
          label: 'Skip for today',
          icon: Icons.next_plan_outlined,
          color: const Color(0xFF6B7280),
          onTap: () {
            ref.read(dailyPlanningProvider.notifier).skipInboxItem(widget.todo.id);
          },
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Empty-inbox state
// ---------------------------------------------------------------------------

class _InboxCleared extends StatelessWidget {
  const _InboxCleared();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inbox_outlined, size: 56, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text(
            'Inbox is clear!',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Tap Next to check in for the day.',
            style: TextStyle(fontSize: 14, color: Colors.grey[400]),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Small widgets
// ---------------------------------------------------------------------------

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.2,
        color: Color(0xFF9CA3AF),
      ),
    );
  }
}

class _EnergyPicker extends StatelessWidget {
  const _EnergyPicker({required this.selected, required this.onSelect});

  final String? selected;
  final void Function(String?) onSelect;

  static const _levels = [
    ('low', 'Low', Color(0xFF16A34A)),
    ('medium', 'Medium', Color(0xFFF59E0B)),
    ('high', 'High', Color(0xFFDC2626)),
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: _levels.map(((String, String, Color) level) {
        final (value, label, color) = level;
        final isSelected = selected == value;
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: GestureDetector(
            onTap: () => onSelect(isSelected ? null : value),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected ? color.withValues(alpha: 0.1) : Colors.transparent,
                border: Border.all(
                  color: isSelected ? color : const Color(0xFFD1D5DB),
                  width: isSelected ? 2 : 1,
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected ? color : const Color(0xFF6B7280),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _EstimateChip extends StatelessWidget {
  const _EstimateChip(
      {required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF2563EB)
              : Colors.transparent,
          border: Border.all(
            color: selected
                ? const Color(0xFF2563EB)
                : const Color(0xFFD1D5DB),
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : const Color(0xFF6B7280),
          ),
        ),
      ),
    );
  }
}

class _DestinationButton extends StatelessWidget {
  const _DestinationButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18, color: color),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.4)),
        alignment: Alignment.centerLeft,
        minimumSize: const Size.fromHeight(44),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}
