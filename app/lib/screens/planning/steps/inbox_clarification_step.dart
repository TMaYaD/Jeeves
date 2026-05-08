/// Step 0 of the daily planning ritual: Clarify Inbox.
///
/// Works through each inbox item one at a time using a fixed snapshot of
/// **IDs** loaded at step start (oldest-first order). Navigation is
/// index-based; the snapshot pins the order, while the per-item attributes
/// (title / notes / energy / time / due) are read live from Drift via
/// [taskDetailTodoProvider]. Edits autosave on change, so they survive Skip
/// and Back without any draft layer in the planning state.
///
/// 1. Prompts the user to clarify the expected outcome (editable title/notes).
/// 2. Lets the user set energy level, time estimate, and due date.
/// 3. Routes the item to the correct GTD list (Next Action, Waiting For,
///    Someday/Maybe, Done, or Skip).
/// 4. Back navigates to the previous item; re-choosing a destination first
///    reverts the prior routing then applies the new one.
///
/// The Next button in the parent is enabled only when the inbox snapshot is
/// fully consumed (inboxNav.isComplete).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/focus_session_planning_provider.dart';
import '../../../providers/task_detail_provider.dart';
import '../../../widgets/clarify_shared_widgets.dart';
import '../../../widgets/person_tag_picker.dart';

class InboxClarificationStep extends ConsumerWidget {
  const InboxClarificationStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nav =
        ref.watch(focusSessionPlanningProvider.select((s) => s.inboxNav));
    final inboxRoutings = ref.watch(
        focusSessionPlanningProvider.select((s) => s.inboxRoutings));

    if (!nav.isLoaded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(focusSessionPlanningProvider.notifier).loadInboxSnapshot();
      });
      return const Center(child: CircularProgressIndicator());
    }

    if (nav.isEmpty || nav.isComplete) {
      return const _InboxCleared();
    }

    final id = nav.current!;
    return _ClarifyCard(
      key: ValueKey(id),
      todoId: id,
      lastRouting: inboxRoutings[nav.index]?.kind,
    );
  }
}

// ---------------------------------------------------------------------------
// Per-item clarification card
// ---------------------------------------------------------------------------

class _ClarifyCard extends ConsumerStatefulWidget {
  const _ClarifyCard({
    super.key,
    required this.todoId,
    this.lastRouting,
  });

  final String todoId;

  /// The last routing applied to this item ('next_action' | 'waiting_for' |
  /// 'maybe' | 'done'), or null if this item has not yet been processed.
  final String? lastRouting;

  @override
  ConsumerState<_ClarifyCard> createState() => _ClarifyCardState();
}

class _ClarifyCardState extends ConsumerState<_ClarifyCard> {
  TextEditingController? _titleCtrl;
  TextEditingController? _notesCtrl;
  String? _energyLevel;
  int? _timeEstimate;
  DateTime? _dueDate;
  bool _initialised = false;
  bool _processing = false;

  /// Debounce text writes so we don't hit the DB on every keystroke. The
  /// debounce is flushed on dispose and before any Process-to call.
  static const _textDebounceMs = 400;
  Timer? _textDebouncer;
  String? _lastSavedTitle;
  String? _lastSavedNotes;

  static const _estimateOptions = [5, 10, 15, 30, 45, 60, 90, 120];

  /// Initialises controllers and chip state from the live todo on first
  /// build; subsequent live-todo updates are not pushed back into the
  /// controllers (the user's in-progress edits are the source of truth
  /// while the card is open and autosave handles the round-trip).
  void _initialiseFrom(Todo todo) {
    if (_initialised) return;
    _initialised = true;
    _titleCtrl = TextEditingController(text: todo.title);
    _notesCtrl = TextEditingController(text: todo.notes ?? '');
    _lastSavedTitle = todo.title;
    _lastSavedNotes = todo.notes ?? '';
    _energyLevel = todo.energyLevel;
    _timeEstimate = todo.timeEstimate;
    // Storage is UTC; the picker and date display below need local-tz
    // semantics so the user sees the calendar day they chose.
    _dueDate = todo.dueDate?.toLocal();
  }

  @override
  void dispose() {
    _textDebouncer?.cancel();
    // Fire-and-forget flush so a final keystroke before nav lands in DB.
    // Safe even on a disposed widget — only touches the captured ref / db.
    unawaited(_flushTextSave());
    _titleCtrl?.dispose();
    _notesCtrl?.dispose();
    super.dispose();
  }

  // ---------- Autosave plumbing ---------------------------------------------

  void _onTextChanged() {
    _textDebouncer?.cancel();
    _textDebouncer = Timer(
      const Duration(milliseconds: _textDebounceMs),
      _flushTextSave,
    );
  }

  /// Writes any pending Title / Notes edits to DB. Empty title is skipped
  /// (a task must have a non-empty title; the user is mid-typing).
  Future<void> _flushTextSave() async {
    _textDebouncer?.cancel();
    _textDebouncer = null;
    final title = _titleCtrl?.text ?? '';
    final notes = _notesCtrl?.text ?? '';
    final trimmedTitle = title.trim();
    final trimmedNotes = notes.trim();
    if (trimmedTitle.isEmpty) return;
    if (title == _lastSavedTitle && notes == _lastSavedNotes) return;
    _lastSavedTitle = title;
    _lastSavedNotes = notes;
    await ref.read(focusSessionPlanningProvider.notifier).updateInboxItemFields(
          widget.todoId,
          title: trimmedTitle,
          notes: trimmedNotes,
        );
  }

  Future<void> _saveEnergy(String? level) async {
    if (level == null) return; // updateFields can't clear; UI doesn't expose null
    await ref
        .read(focusSessionPlanningProvider.notifier)
        .updateInboxItemFields(widget.todoId, energyLevel: level);
  }

  Future<void> _saveTimeEstimate(int? minutes) async {
    if (minutes == null) return; // updateFields can't clear time estimate
    await ref
        .read(focusSessionPlanningProvider.notifier)
        .updateInboxItemFields(widget.todoId, timeEstimate: minutes);
  }

  Future<void> _saveDueDate(DateTime? date, {required bool clear}) async {
    await ref
        .read(focusSessionPlanningProvider.notifier)
        .updateInboxItemFields(
          widget.todoId,
          dueDate: date,
          clearDueDate: clear,
        );
  }

  // ---------- Process-to handlers -------------------------------------------

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

  /// Returns the title to use for a Process-to call after flushing any
  /// pending text edit to DB. Returns null if the title is empty (in which
  /// case the routing call should be skipped).
  Future<String?> _flushAndGetTitle() async {
    await _flushTextSave();
    final title = _titleCtrl?.text.trim() ?? '';
    if (title.isEmpty) return null;
    return title;
  }

  Future<void> _process(BuildContext context) async {
    if (!mounted) return;
    final title = await _flushAndGetTitle();
    if (title == null || !context.mounted) return;
    Object? error;
    try {
      await ref
          .read(focusSessionPlanningProvider.notifier)
          .processInboxItem(widget.todoId, title: title);
    } catch (e) {
      error = e;
    }
    if (!context.mounted) return;
    if (error != null) debugPrint('Error: $error');
  }

  Future<void> _processToWaitingFor(BuildContext context) async {
    if (!mounted) return;
    final title = await _flushAndGetTitle();
    if (title == null || !context.mounted) return;

    // Fetch currently assigned person tags so a revisit pre-selects them.
    final currentTagIds = await ref
        .read(focusSessionPlanningProvider.notifier)
        .getPersonTagIds(widget.todoId);

    if (!context.mounted) return;

    await showPersonTagPicker(
      context,
      todoId: widget.todoId,
      assignedPersonTagIds: currentTagIds,
      requireSelection: true,
      onAfterConfirm: () async {
        if (!context.mounted) return;
        Object? error;
        try {
          await ref
              .read(focusSessionPlanningProvider.notifier)
              .processInboxItemToWaitingFor(widget.todoId, title: title);
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
    final title = await _flushAndGetTitle();
    if (title == null || !context.mounted) return;
    Object? error;
    try {
      await ref
          .read(focusSessionPlanningProvider.notifier)
          .processInboxItemToDone(widget.todoId);
    } catch (e) {
      error = e;
    }
    if (!context.mounted) return;
    if (error != null) debugPrint('Error: $error');
  }

  Future<void> _processToMaybe(BuildContext context) async {
    if (!mounted) return;
    final title = await _flushAndGetTitle();
    if (title == null || !context.mounted) return;
    Object? error;
    try {
      await ref
          .read(focusSessionPlanningProvider.notifier)
          .processInboxItemToMaybe(widget.todoId);
    } catch (e) {
      error = e;
    }
    if (!context.mounted) return;
    if (error != null) debugPrint('Error: $error');
  }

  Future<void> _processToTrash(BuildContext context) async {
    if (!mounted) return;
    final title = await _flushAndGetTitle();
    if (title == null || !context.mounted) return;
    Object? error;
    try {
      await ref
          .read(focusSessionPlanningProvider.notifier)
          .processInboxItemToTrash(widget.todoId);
    } catch (e) {
      error = e;
    }
    if (!context.mounted) return;
    if (error != null) debugPrint('Error: $error');
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
    final todoAsync = ref.watch(taskDetailTodoProvider(widget.todoId));
    final todo = todoAsync.value;
    if (todo == null) {
      // First-load (or row gone): show a light placeholder. We do not block
      // rebuilds on subsequent loads since [_initialised] guards re-init.
      return const Center(child: CircularProgressIndicator());
    }
    _initialiseFrom(todo);

    return ListView(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
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
          onChanged: (_) => _onTextChanged(),
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
          onChanged: (_) => _onTextChanged(),
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
          onSelect: (level) {
            setState(() => _energyLevel = level);
            unawaited(_saveEnergy(level));
          },
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
              onTap: () {
                final newValue = selected ? null : m;
                setState(() => _timeEstimate = newValue);
                unawaited(_saveTimeEstimate(newValue));
              },
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
                  unawaited(_saveDueDate(picked, clear: false));
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
                onPressed: () {
                  setState(() => _dueDate = null);
                  unawaited(_saveDueDate(null, clear: true));
                },
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
                isPreviouslySelected: widget.lastRouting == 'next_action',
                onTap: () => _runAction(() => _process(context)),
              ),
              const SizedBox(height: 8),
              ClarifyDestinationButton(
                label: 'Waiting For',
                icon: Icons.hourglass_empty,
                color: const Color(0xFFF59E0B),
                enabled: !_processing,
                isPreviouslySelected: widget.lastRouting == 'waiting_for',
                onTap: () => _runAction(() => _processToWaitingFor(context)),
              ),
              const SizedBox(height: 8),
              ClarifyDestinationButton(
                label: 'Maybe',
                icon: Icons.star_border,
                color: const Color(0xFF6B7280),
                enabled: !_processing,
                isPreviouslySelected: widget.lastRouting == 'maybe',
                onTap: () => _runAction(() => _processToMaybe(context)),
              ),
              const SizedBox(height: 8),
              ClarifyDestinationButton(
                label: 'Done',
                icon: Icons.task_alt,
                color: const Color(0xFF0EA5E9),
                enabled: !_processing,
                isPreviouslySelected: widget.lastRouting == 'done',
                onTap: () => _runAction(() => _processToDone(context)),
              ),
              const SizedBox(height: 8),
              ClarifyDestinationButton(
                label: 'Discard',
                icon: Icons.delete_outline,
                color: const Color(0xFFDC2626),
                enabled: !_processing,
                isPreviouslySelected: widget.lastRouting == 'trash',
                onTap: () => _runAction(() => _processToTrash(context)),
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
