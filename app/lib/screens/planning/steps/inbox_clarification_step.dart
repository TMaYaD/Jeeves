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

import '../../../providers/auth_provider.dart';
import '../../../providers/database_provider.dart';
import '../../../providers/focus_session_planning_provider.dart';
import '../../../providers/inbox_provider.dart';
import '../../../widgets/clarify_shared_widgets.dart';
import '../../../widgets/person_tag_picker.dart';

class InboxClarificationStep extends ConsumerWidget {
  const InboxClarificationStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncItems = ref.watch(inboxItemsProvider);

    return asyncItems.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Error: $err')),
      data: (items) {
        final pendingItems = items;

        WidgetsBinding.instance.addPostFrameCallback((_) {
          final state = ref.read(focusSessionPlanningProvider);
          if (state.initialInboxCount == null) {
            ref.read(focusSessionPlanningProvider.notifier).setInitialInboxCount(pendingItems.length);
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
  bool _processing = false;

  static const _estimateOptions = [5, 10, 15, 30, 45, 60, 90, 120];

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.todo.title);
    _notesCtrl = TextEditingController(text: widget.todo.notes ?? '');
    _energyLevel = widget.todo.energyLevel;
    _timeEstimate = widget.todo.timeEstimate;
    // Storage is UTC; the picker and the year/month/day display below need
    // local-tz semantics so the user sees the calendar day they chose.
    _dueDate = widget.todo.dueDate?.toLocal();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  /// Runs [action] with a re-entry guard so rapid taps cannot fire concurrent
  /// DB writes on the same item.
  Future<void> _runAction(Future<void> Function() action) async {
    if (_processing) return;
    setState(() => _processing = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _processing = false);
    }
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
    await ref.read(focusSessionPlanningProvider.notifier).updateInboxItemFields(
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

  Future<void> _process(BuildContext context) async {
    if (!mounted) return;
    Object? error;
    try {
      final saved = await _saveFields(context);
      if (!saved || !context.mounted) return;
      await ref
          .read(focusSessionPlanningProvider.notifier)
          .processInboxItem(widget.todo.id);
    } catch (e) {
      error = e;
    }

    if (!context.mounted) return;
    if (error != null) {
      debugPrint('Error: $error');
    }
  }

  Future<void> _processToWaitingFor(BuildContext context) async {
    if (!mounted) return;
    final saved = await _saveFields(context);
    if (!saved || !context.mounted) return;

    await showPersonTagPicker(
      context,
      todoId: widget.todo.id,
      assignedPersonTagIds: const {},
      requireSelection: true,
      onAfterConfirm: () async {
        if (!context.mounted) return;
        Object? error;
        try {
          await ref
              .read(focusSessionPlanningProvider.notifier)
              .processInboxItem(widget.todo.id);
        } catch (e) {
          error = e;
        }
        if (!context.mounted) return;
        if (error != null) {
          debugPrint('Error: $error');
          await showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Save failed'),
              content: const Text('Failed to save. Please try again.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
        }
      },
    );
  }

  Future<void> _processToDone(BuildContext context) async {
    if (!mounted) return;
    Object? error;
    try {
      final saved = await _saveFields(context);
      if (!saved || !context.mounted) return;
      final db = ref.read(databaseProvider);
      final userId = ref.read(currentUserIdProvider);
      await db.todoDao.markDone(widget.todo.id, userId);
    } catch (e) {
      error = e;
    }
    if (!context.mounted) return;
    if (error != null) debugPrint('Error: $error');
  }

  Future<void> _processToMaybe(BuildContext context) async {
    if (!mounted) return;
    Object? error;
    try {
      final saved = await _saveFields(context);
      if (!saved || !context.mounted) return;
      await ref
          .read(focusSessionPlanningProvider.notifier)
          .processInboxItemToMaybe(widget.todo.id);
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
        ClarifyFieldLabel('ENERGY LEVEL'),
        const SizedBox(height: 8),
        ClarifyEnergyPicker(
          selected: _energyLevel,
          onSelect: (level) => setState(() => _energyLevel = level),
        ),
        const SizedBox(height: 20),

        // Time estimate
        ClarifyFieldLabel('TIME ESTIMATE'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _estimateOptions.map((m) {
            final selected = _timeEstimate == m;
            return ClarifyEstimateChip(
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
        ClarifyFieldLabel('DUE DATE'),
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

        // Destination buttons — dimmed while a write is in flight to signal
        // the commit is pending and to block concurrent taps.
        AnimatedOpacity(
          opacity: _processing ? 0.4 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ClarifyFieldLabel('PROCESS TO'),
              const SizedBox(height: 12),
              ClarifyDestinationButton(
                label: 'Next Action',
                icon: Icons.check_circle_outline,
                color: const Color(0xFF16A34A),
                enabled: !_processing,
                onTap: () => _runAction(() => _process(context)),
              ),
              const SizedBox(height: 8),
              ClarifyDestinationButton(
                label: 'Waiting For',
                icon: Icons.hourglass_empty,
                color: const Color(0xFFF59E0B),
                enabled: !_processing,
                onTap: () => _runAction(() => _processToWaitingFor(context)),
              ),
              const SizedBox(height: 8),
              ClarifyDestinationButton(
                label: 'Maybe',
                icon: Icons.star_border,
                color: const Color(0xFF6B7280),
                enabled: !_processing,
                onTap: () => _runAction(() => _processToMaybe(context)),
              ),
              const SizedBox(height: 8),
              ClarifyDestinationButton(
                label: 'Done (discard)',
                icon: Icons.delete_outline,
                color: const Color(0xFFDC2626),
                enabled: !_processing,
                onTap: () => _runAction(() => _processToDone(context)),
              ),
              const SizedBox(height: 20),
              ClarifyDestinationButton(
                label: 'Skip for today',
                icon: Icons.next_plan_outlined,
                color: const Color(0xFF6B7280),
                enabled: !_processing,
                onTap: () => _runAction(() async {
                  ref.read(focusSessionPlanningProvider.notifier).skipInboxItem(widget.todo.id);
                }),
              ),
            ],
          ),
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

