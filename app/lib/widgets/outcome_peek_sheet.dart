/// The bottom sheet that peeks at, and edits, an Outcome during Daily Planning
/// (#462, #698).
///
/// Opened by a plain tap on a Plan Summary card (outside multi-select). It looks
/// like a viewer until a field is tapped: title and notes are borderless fields
/// saved on focus loss (and flushed on dismissal), the effort / due chips and
/// the context, delegate and Plan sections reuse the Task Detail editors. Every
/// write goes through `TaskDetailNotifier`; opening or dismissing without an
/// edit writes nothing. It never reads or writes the pick-up/skip selection
/// (the modal sits *over* the never-unmounted list, preserving scroll and
/// selection). Status changes and project assignment are not offered here.
///
/// Time logged is derived from the `time_logs` table via
/// [TimeLogDao.totalMinutesForTask] — the only source of truth for time spent
/// (nothing stores a total).
library;

import 'dart:async';

import 'package:flutter/material.dart' hide Action;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../providers/database_provider.dart';
import '../providers/task_detail_provider.dart';
import 'meta_chip.dart';
import 'outcome_attribute_editors.dart';
import 'time_context_sheet.dart';
import 'outcome_plan_section.dart';
import 'person_tag_picker.dart';
import 'tag_list.dart';

/// One-shot read of the ceiling-rounded minutes logged against [taskId],
/// summed from the `time_logs` rows. Resolved fresh each time the sheet
/// opens — `.autoDispose` drops the cached value once nothing is watching
/// it, so re-opening the peek for the same task re-reads
/// [TimeLogDao.totalMinutesForTask] instead of replaying a stale total.
final outcomePeekTimeLoggedProvider =
    FutureProvider.autoDispose.family<int, String>((ref, taskId) {
  return ref.watch(databaseProvider).timeLogDao.totalMinutesForTask(taskId);
});

class OutcomePeekSheet extends ConsumerStatefulWidget {
  const OutcomePeekSheet({super.key, required this.todo});

  /// The Outcome as it was when the card was tapped. Only the first frame —
  /// the sheet watches the live row from then on.
  final Todo todo;

  /// Opens the peek sheet for [todo]. Opening and dismissing write nothing; the
  /// caller's scroll and selection state are untouched.
  static Future<void> show(BuildContext context, Todo todo) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        // Sheets sit at 6px on the canonical 2/4/6 scale (DESIGN.md §Roundedness).
        borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
      ),
      builder: (_) => OutcomePeekSheet(todo: todo),
    );
  }

  @override
  ConsumerState<OutcomePeekSheet> createState() => _OutcomePeekSheetState();
}

class _OutcomePeekSheetState extends ConsumerState<OutcomePeekSheet> {
  late final TextEditingController _titleController;
  late final TextEditingController _notesController;
  final FocusNode _titleFocus = FocusNode();
  final FocusNode _notesFocus = FocusNode();

  /// Trimmed text last written (or loaded). A save only fires when the trimmed
  /// field differs: `updateFields` stamps `last_clarified_at` and authors a
  /// sync op on any call, so a redundant write is not harmless.
  late String _baselineTitle;
  late String _baselineNotes;

  /// Captured in [initState]: [dispose] flushes through it and must not touch
  /// `ref`.
  late final TaskDetailNotifier _notifier;

  @override
  void initState() {
    super.initState();
    _notifier = ref.read(taskDetailNotifierProvider(widget.todo.id));
    _titleController = TextEditingController(text: widget.todo.title);
    _notesController = TextEditingController(text: widget.todo.notes ?? '');
    _baselineTitle = widget.todo.title.trim();
    _baselineNotes = (widget.todo.notes ?? '').trim();
    _titleFocus.addListener(() {
      if (!_titleFocus.hasFocus) _saveTitle();
    });
    _notesFocus.addListener(() {
      if (!_notesFocus.hasFocus) _saveNotes();
    });
  }

  @override
  void dispose() {
    // Dismissal while a field still has focus (swipe, barrier tap, back) never
    // delivers a focus-loss event we can act on, so flush what is in the field.
    _saveTitle();
    _saveNotes();
    _titleFocus.dispose();
    _notesFocus.dispose();
    _titleController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  /// Adopts a changed stored value for a field the user has not touched: the
  /// field's trimmed text still equals the last baseline and it has no focus.
  /// A field with a local edit in flight keeps the user's text.
  void _reconcileWithRow(Todo? row) {
    if (row == null) return;
    final rowTitle = row.title.trim();
    if (!_titleFocus.hasFocus &&
        _titleController.text.trim() == _baselineTitle &&
        rowTitle != _baselineTitle) {
      _baselineTitle = rowTitle;
      _titleController.text = row.title;
    }
    final rowNotes = (row.notes ?? '').trim();
    if (!_notesFocus.hasFocus &&
        _notesController.text.trim() == _baselineNotes &&
        rowNotes != _baselineNotes) {
      _baselineNotes = rowNotes;
      _notesController.text = row.notes ?? '';
    }
  }

  void _saveTitle() {
    final title = _titleController.text.trim();
    // An emptied title is not a title; keep the stored one.
    if (title.isEmpty || title == _baselineTitle) return;
    _baselineTitle = title;
    unawaited(_notifier.updateTitle(title).catchError((Object e) {
      debugPrint('OutcomePeekSheet: title save failed: $e');
      return false;
    }));
  }

  void _saveNotes() {
    final notes = _notesController.text.trim();
    if (notes == _baselineNotes) return;
    _baselineNotes = notes;
    unawaited(_notifier.updateNotes(notes).catchError((Object e) {
      debugPrint('OutcomePeekSheet: notes save failed: $e');
      return false;
    }));
  }

  @override
  Widget build(BuildContext context) {
    final todoId = widget.todo.id;
    final todoAsync = ref.watch(taskDetailTodoProvider(todoId));
    ref.listen(taskDetailTodoProvider(todoId), (_, next) {
      _reconcileWithRow(next.asData?.value);
    });
    final tags = ref.watch(taskTagsProvider(todoId)).asData?.value ??
        const <Tag>[];
    final timeLogged = ref.watch(outcomePeekTimeLoggedProvider(todoId));

    // Deleted while open: the stream has resolved to "no row".
    final isMissing = todoAsync.hasValue && todoAsync.value == null;
    final todo = todoAsync.asData?.value ?? widget.todo;
    final contextTags = tags.where((t) => t.type == 'context').toList();
    final personTags = tags.where((t) => t.type == 'person').toList();
    final dueDate = todo.dueDate;
    final energyLevel = todo.energyLevel;
    final timeEstimate = todo.timeEstimate;

    return Semantics(
      label: 'Outcome details',
      container: true,
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.9,
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
                20, 8, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Drag handle for affordance.
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE5E7EB),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                if (isMissing)
                  _MissingOutcome(onClose: () => Navigator.of(context).maybePop())
                else ...[
                  // Header: title + close.
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('outcome_peek_title'),
                          controller: _titleController,
                          focusNode: _titleFocus,
                          maxLines: null,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1A1A2E),
                          ),
                          decoration: const InputDecoration(
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                            border: InputBorder.none,
                            hintText: 'Title',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Tooltip(
                        message: 'Close',
                        child: InkWell(
                          onTap: () => Navigator.of(context).maybePop(),
                          borderRadius: BorderRadius.circular(4),
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(Icons.close,
                                size: 22, color: Color(0xFF6B7280)),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Meta chips: energy, time estimate, due date are
                          // tappable (the gesture sits on the ancestor, per
                          // MetaChip); time logged is derived and read-only.
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _TapChip(
                                key: const Key('outcome_peek_energy'),
                                onTap: () => showOutcomeEnergyLevelSheet(
                                    context, _notifier, energyLevel),
                                child: MetaChip(
                                  icon: Icons.bolt_outlined,
                                  label: energyLevel != null
                                      ? energyLevelLabel(energyLevel)
                                      : 'Energy',
                                  color: energyLevel != null
                                      ? const Color(0xFF7C3AED)
                                      : const Color(0xFF9CA3AF),
                                ),
                              ),
                              _TapChip(
                                key: const Key('outcome_peek_time'),
                                onTap: () => showOutcomeTimeEstimateSheet(
                                    context, _notifier, timeEstimate),
                                child: MetaChip(
                                  icon: Icons.timer_outlined,
                                  label: timeEstimate != null
                                      ? formatMinutesLabel(timeEstimate)
                                      : 'Time',
                                  color: timeEstimate != null
                                      ? const Color(0xFF2563EB)
                                      : const Color(0xFF9CA3AF),
                                ),
                              ),
                              _TimeLoggedChip(value: timeLogged),
                              TimeContextChip(outcomeId: widget.todo.id),
                              _TapChip(
                                key: const Key('outcome_peek_due'),
                                onTap: () async {
                                  final picked =
                                      await pickOutcomeDueDate(context, dueDate);
                                  // Null is a dismissed picker, not a clear.
                                  if (picked != null) {
                                    unawaited(_notifier.setDueDate(picked));
                                  }
                                },
                                child: MetaChip(
                                  icon: Icons.event_outlined,
                                  label: dueDate != null
                                      ? formatDueDateLabel(dueDate)
                                      : 'Due',
                                  color: dueDate != null
                                      ? const Color(0xFFDC2626)
                                      : const Color(0xFF9CA3AF),
                                ),
                              ),
                              if (dueDate != null)
                                InkResponse(
                                  key: const Key('outcome_peek_due_clear'),
                                  onTap: () => unawaited(_notifier.clearDueDate()),
                                  radius: 16,
                                  child: const Tooltip(
                                    message: 'Clear date',
                                    child: Padding(
                                      padding: EdgeInsets.all(4),
                                      child: Icon(Icons.close,
                                          size: 16, color: Color(0xFF9CA3AF)),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          const _FieldLabel('Contexts'),
                          const SizedBox(height: 6),
                          TagList(
                            tags: contextTags,
                            spacing: 12,
                            runSpacing: 8,
                            onTap: (_) =>
                                showOutcomeContextTagEditor(context, todoId),
                            trailing: GestureDetector(
                              key: const Key('outcome_peek_add_context'),
                              onTap: () =>
                                  showOutcomeContextTagEditor(context, todoId),
                              child: Container(
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                      color: const Color(0xFFD1D5DB)),
                                ),
                                child: const Icon(Icons.add,
                                    size: 16, color: Color(0xFF9CA3AF)),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          const _FieldLabel('Waiting for'),
                          const SizedBox(height: 6),
                          InkWell(
                            key: const Key('outcome_peek_delegates'),
                            onTap: () => showPersonTagPicker(
                              context,
                              todoId: todoId,
                              assignedPersonTagIds:
                                  personTags.map((t) => t.id).toSet(),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Text(
                                personTags.isEmpty
                                    ? 'Nobody'
                                    : personTags.map((t) => t.name).join(', '),
                                style: TextStyle(
                                  fontSize: 14,
                                  color: personTags.isEmpty
                                      ? const Color(0xFF9CA3AF)
                                      : const Color(0xFF374151),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          OutcomePlanSection(outcomeId: todoId),
                          const SizedBox(height: 16),
                          const _FieldLabel('Notes'),
                          const SizedBox(height: 6),
                          TextField(
                            key: const Key('outcome_peek_notes'),
                            controller: _notesController,
                            focusNode: _notesFocus,
                            minLines: 1,
                            maxLines: null,
                            style: const TextStyle(
                              fontSize: 14,
                              height: 1.4,
                              color: Color(0xFF374151),
                            ),
                            decoration: const InputDecoration(
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                              border: InputBorder.none,
                              hintText: 'Add notes',
                              hintStyle: TextStyle(color: Color(0xFF9CA3AF)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TapChip extends StatelessWidget {
  const _TapChip({super.key, required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: child,
    );
  }
}

/// Same copy as the detail screen's missing state: to the user an Outcome that
/// is gone is gone, whichever surface was showing it.
class _MissingOutcome extends StatelessWidget {
  const _MissingOutcome({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.inventory_2_outlined,
              size: 32, color: Color(0xFF9CA3AF)),
          const SizedBox(height: 8),
          const Text('This item is no longer here',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          const Text('It was removed while you had it open.',
              style: TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
          TextButton(onPressed: onClose, child: const Text('Close')),
        ],
      ),
    );
  }
}

/// The time-logged chip. Renders a subtle placeholder while the one-shot read
/// resolves; `0` shows as "no time logged yet".
class _TimeLoggedChip extends StatelessWidget {
  const _TimeLoggedChip({required this.value});

  final AsyncValue<int> value;

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFF16A34A);
    final label = value.when(
      data: (minutes) =>
          minutes <= 0 ? 'No time logged yet' : formatMinutesLabel(minutes),
      loading: () => '…',
      error: (_, _) => '—',
    );
    return MetaChip(
      icon: Icons.history_toggle_off_outlined,
      label: label,
      color: color,
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.label);
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
