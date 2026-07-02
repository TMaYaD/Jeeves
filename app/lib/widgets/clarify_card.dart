/// Generic clarification card. Renders an editable view of a [Todo] plus the
/// canonical [ProcessToHandlers] action bar.
///
/// The card autosaves attribute edits (title / notes / energy / time / due)
/// directly to [TodoDao]; routing actions are delegated to the canonical
/// [ProcessToHandlers] action bar, which owns its own DAO writes. Per-flow
/// nav side-effects (recording routing history, advancing the cursor) are
/// wired through [onAfterRoute].
///
/// Used by the daily-planning ritual's inbox-clarify step and by the
/// Weekly Review wizard (zero-inbox step + the `reclarify` sub-flow opened
/// from the Waiting For / Next Actions / Someday-Maybe steps).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../providers/database_provider.dart';
import '../providers/task_detail_provider.dart';
import 'clarify_shared_widgets.dart';
import 'context_tag_picker.dart';
import 'process_to_handlers.dart';
import 'project_picker.dart';

/// Distinguishes the inbox-clarify caller (always mirror title into
/// `next_action_text` on Next/WaitingFor) from the re-clarify sub-flow on a
/// previously-clarified item (only mirror when the existing
/// `next_action_text` is null/empty so a deliberately written phrase is not
/// clobbered).
enum ClarifyMode { inbox, reclarify }

/// Generic clarification card. Renders an editable view of [todoId] plus the
/// canonical "process to" action bar. Title/notes/energy/time/due autosave
/// directly via [TodoDao]; routing buttons drive [ProcessToHandlers].
class ClarifyCard extends ConsumerStatefulWidget {
  const ClarifyCard({
    super.key,
    required this.todoId,
    this.mode = ClarifyMode.inbox,
    this.lastAction,
    this.onAfterRoute,
  });

  final String todoId;

  /// Selects the title-as-action mirror policy applied in [onAfterRoute].
  /// See [ClarifyMode].
  final ClarifyMode mode;

  /// The action most recently applied to this item — drives the
  /// "previously selected" affordance on the matching destination button.
  final ProcessAction? lastAction;

  /// Called once after a successful route. Used for callsite-specific
  /// concerns like advancing the inbox cursor and recording routing history.
  final Future<void> Function(ProcessAction action)? onAfterRoute;

  @override
  ConsumerState<ClarifyCard> createState() => _ClarifyCardState();
}

class _ClarifyCardState extends ConsumerState<ClarifyCard> {
  TextEditingController? _titleCtrl;
  TextEditingController? _notesCtrl;
  String? _energyLevel;
  int? _timeEstimate;
  DateTime? _dueDate;
  bool _initialised = false;
  // Mirrors `_titleCtrl.text.trim().isEmpty` for build-time gating of the
  // routing buttons. Updated synchronously in `_onTextChanged` so the user
  // sees the destination buttons (and the title's error state) react as
  // they type — without a SnackBar or other toast surface.
  bool _titleIsBlank = false;

  static const _textDebounceMs = 400;
  Timer? _textDebouncer;
  String? _lastSavedTitle;
  String? _lastSavedNotes;

  static const _estimateOptions = [5, 10, 15, 30, 45, 60, 90, 120];

  void _initialiseFrom(Todo todo) {
    if (_initialised) return;
    _initialised = true;
    _titleCtrl = TextEditingController(text: todo.title);
    _notesCtrl = TextEditingController(text: todo.notes ?? '');
    _lastSavedTitle = todo.title.trim();
    _lastSavedNotes = (todo.notes ?? '').trim();
    _titleIsBlank = todo.title.trim().isEmpty;
    _energyLevel = todo.energyLevel;
    _timeEstimate = todo.timeEstimate;
    _dueDate = todo.dueDate?.toLocal();
  }

  @override
  void dispose() {
    _textDebouncer?.cancel();
    _textDebouncer = null;
    // Snapshot pending edits and the DAO reference up-front so the
    // fire-and-forget flush below doesn't touch disposed controllers or
    // assign back into a disposed State (which `_flushTextSave` would do
    // when updating `_lastSavedTitle` / `_lastSavedNotes` after its await).
    final trimmedTitle = (_titleCtrl?.text ?? '').trim();
    final trimmedNotes = (_notesCtrl?.text ?? '').trim();
    final hasPendingWrite = trimmedTitle.isNotEmpty &&
        (trimmedTitle != _lastSavedTitle || trimmedNotes != _lastSavedNotes);
    if (hasPendingWrite) {
      final dao = ref.read(databaseProvider).todoDao;
      unawaited(dao.updateFields(
        widget.todoId,
        title: trimmedTitle,
        notes: trimmedNotes,
      ));
    }
    _titleCtrl?.dispose();
    _notesCtrl?.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final blank = (_titleCtrl?.text ?? '').trim().isEmpty;
    if (blank != _titleIsBlank) {
      setState(() => _titleIsBlank = blank);
    }
    _textDebouncer?.cancel();
    _textDebouncer = Timer(
      const Duration(milliseconds: _textDebounceMs),
      _flushTextSave,
    );
  }

  Future<void> _flushTextSave() async {
    _textDebouncer?.cancel();
    _textDebouncer = null;
    final trimmedTitle = (_titleCtrl?.text ?? '').trim();
    final trimmedNotes = (_notesCtrl?.text ?? '').trim();
    if (trimmedTitle.isEmpty) return;
    if (trimmedTitle == _lastSavedTitle && trimmedNotes == _lastSavedNotes) {
      return;
    }
    final db = ref.read(databaseProvider);
    await db.todoDao.updateFields(
      widget.todoId,
      title: trimmedTitle,
      notes: trimmedNotes,
    );
    _lastSavedTitle = trimmedTitle;
    _lastSavedNotes = trimmedNotes;
  }

  Future<void> _saveEnergy(String? level) async {
    if (level == null) return;
    final db = ref.read(databaseProvider);
    await db.todoDao.updateFields(widget.todoId, energyLevel: level);
  }

  Future<void> _saveTimeEstimate(int? minutes) async {
    final db = ref.read(databaseProvider);
    await db.todoDao.updateFields(
      widget.todoId,
      timeEstimate: minutes,
      clearTimeEstimate: minutes == null,
    );
  }

  Future<void> _saveDueDate(DateTime? date, {required bool clear}) async {
    final db = ref.read(databaseProvider);
    await db.todoDao.updateFields(
      widget.todoId,
      dueDate: date,
      clearDueDate: clear,
    );
  }

  // Tag edits route through [TaskDetailNotifier], which owns the
  // single-project invariant and user-scoped writes. None of these methods
  // touches `todos.intent` or person-tag join rows, so the intent ⊥ delegate
  // orthogonality invariant (ARCHITECTURE.md) is preserved structurally.
  // Unlike the person-tag methods, context/project edits deliberately do NOT
  // stamp `last_clarified_at` — the categorisation axes are not the clarified
  // moment (matches task_detail_screen behaviour).
  TaskDetailNotifier get _tagNotifier =>
      ref.read(taskDetailNotifierProvider(widget.todoId));

  Future<void> _saveAssignProject(String tagId) =>
      _tagNotifier.assignProject(tagId);

  Future<void> _saveClearProject() => _tagNotifier.clearProject();

  Future<void> _saveAssignContext(String tagId) =>
      _tagNotifier.assignContextTag(tagId);

  Future<void> _saveRemoveContext(String tagId) =>
      _tagNotifier.removeContextTag(tagId);

  Future<DateTime?> _pickDate(BuildContext context) {
    final now = DateTime.now();
    final candidate = _dueDate ?? now.add(const Duration(days: 1));
    final initial = candidate.isBefore(now) ? now : candidate;
    return showDatePicker(
      context: context,
      initialDate: initial,
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
      return const Center(child: CircularProgressIndicator());
    }
    _initialiseFrom(todo);

    // Tags are watched live so the pickers re-render on DB change; keeping a
    // local mirror would go stale across the async write. Person tags are
    // intentionally excluded here — they are edited via the Waiting For
    // routing button (which opens PersonTagPickerSheet), never on this card.
    final tagsAsync = ref.watch(taskTagsProvider(widget.todoId));
    final allTags = tagsAsync.asData?.value ?? const <Tag>[];
    final projectTags = allTags.where((t) => t.type == 'project').toList();
    final projectTag = projectTags.isEmpty ? null : projectTags.first;
    final contextTags = allTags.where((t) => t.type == 'context').toList();

    // Title is required to route to anything except Trash. Disable the
    // four committed routes; Trash stays enabled so the user can throw away
    // an unnamed item.
    final disabled = _titleIsBlank
        ? const <ProcessAction>{
            ProcessAction.next,
            ProcessAction.waitingFor,
            ProcessAction.someday,
            ProcessAction.done,
          }
        : const <ProcessAction>{};

    return ListView(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFEFF6FF),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFDBEAFE)),
          ),
          child: const Row(
            children: [
              Icon(Icons.help_outline,
                  size: 18, color: Color(0xFF2563EB)),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  "What's the expected outcome?",
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

        TextField(
          controller: _titleCtrl,
          onChanged: (_) => _onTextChanged(),
          decoration: InputDecoration(
            labelText: 'Title',
            errorText: _titleIsBlank ? 'Title is required to process' : null,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          textCapitalization: TextCapitalization.sentences,
          maxLines: 2,
          minLines: 1,
        ),
        const SizedBox(height: 12),

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

        const ClarifyFieldLabel('TAGS'),
        const SizedBox(height: 8),
        // Project row — single-select; reuse ProjectPickerWidget so styling
        // matches task_detail_screen.dart. Its "No project" state doubles as
        // the optional-tag hint.
        ProjectPickerWidget(
          currentProjectTag: projectTag,
          onAssign: (t) => unawaited(_saveAssignProject(t.id)),
          onClear: () => unawaited(_saveClearProject()),
        ),
        const SizedBox(height: 12),
        // Context row — multi-select; reuse ContextTagPickerWidget. Its
        // "+ context" trailing affordance doubles as the optional-tag hint.
        ContextTagPickerWidget(
          assignedTags: contextTags,
          onAssign: (t) => unawaited(_saveAssignContext(t.id)),
          onRemove: (t) => unawaited(_saveRemoveContext(t.id)),
        ),
        const SizedBox(height: 20),

        const ClarifyFieldLabel('ENERGY LEVEL'),
        const SizedBox(height: 8),
        ClarifyEnergyPicker(
          selected: _energyLevel,
          onSelect: (level) {
            setState(() => _energyLevel = level);
            unawaited(_saveEnergy(level));
          },
        ),
        const SizedBox(height: 20),

        const ClarifyFieldLabel('TIME ESTIMATE'),
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

        const ClarifyFieldLabel('DUE DATE'),
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

        const ClarifyFieldLabel('PROCESS TO'),
        const SizedBox(height: 12),
        ProcessToHandlers(
          todo: todo,
          disabled: disabled,
          // Opt out of the default-on `nextActionDialog` modifier: the
          // clarify card supplies the phrase via the title-as-action
          // coupling below, so tapping Next should route immediately
          // rather than popping the dialog.
          except: const {ProcessAction.nextActionDialog},
          lastAction: widget.lastAction,
          onAfterRoute: (action) async {
            // Make sure title/notes are persisted before yielding to the
            // caller's nav handler — the inbox cursor advance reads the
            // recorded routing on the next item.
            await _flushTextSave();
            // Title-as-action coupling: when the user routes to Next or
            // Waiting For from a clarify card, mirror the current title
            // into `next_action_text` so the row leaves with a defined
            // action. The controller's live value wins over the (possibly
            // debounced) todos.title column so a fast typer's edit isn't
            // lost. With the dialog modifier excepted, Next reports plain
            // `next`.
            //
            // ClarifyMode.inbox     → always mirror (the row is fresh, so
            //                         any existing phrase is stale or
            //                         missing).
            // ClarifyMode.reclarify → only mirror when `next_action_text`
            //                         is null/empty; otherwise the user
            //                         has already written a deliberate
            //                         phrase and we must not clobber it.
            if (action == ProcessAction.next ||
                action == ProcessAction.waitingFor) {
              final title = _titleCtrl?.text.trim() ?? '';
              if (title.isNotEmpty) {
                var shouldMirror = widget.mode == ClarifyMode.inbox;
                if (!shouldMirror) {
                  final current = await ref
                      .read(databaseProvider)
                      .todoDao
                      .getTodo(widget.todoId);
                  final existing = current?.nextActionText?.trim() ?? '';
                  shouldMirror = existing.isEmpty;
                }
                if (shouldMirror) {
                  await ref
                      .read(databaseProvider)
                      .todoDao
                      .setNextActionText(widget.todoId, title);
                }
              }
            }
            await widget.onAfterRoute?.call(action);
          },
        ),
      ],
    );
  }
}
