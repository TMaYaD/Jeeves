/// Generic clarification card. Renders an editable view of a Capture or an
/// Outcome plus the canonical [ProcessToHandlers] action bar.
///
/// Two shapes, matching the ADR-0006 split:
///
/// - [ClarifyCard.forCapture] — an Inbox Capture on its first pass through the
///   flow. Title and notes autosave onto the Capture. Energy, time estimate
///   and due date have **no column on a Capture** (they are Outcome
///   attributes), so the card holds them as draft state and
///   [ClarificationService.clarifyCaptureToOutcome] writes them onto the
///   Outcome it mints. Tag edits persist as *tag hints* (`capture_tags`) which
///   seed that Outcome's tags, so — like the text — they survive Skip and Back
///   even though no Outcome exists yet.
/// - [ClarifyCard.forOutcome] — the re-clarify sub-flow on an already
///   clarified Outcome. Every edit autosaves straight to `todos`, as before.
///
/// Routing is delegated to [ProcessToHandlers], which owns the write for
/// whichever subject it is given. Per-flow nav side-effects (recording routing
/// history, advancing the cursor) are wired through [onAfterRoute].
///
/// Used by the daily-planning ritual's inbox-clarify step and by the
/// Weekly Review wizard (zero-inbox step + the `reclarify` sub-flow opened
/// from the Waiting For / Next Actions / Someday-Maybe steps).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../providers/auth_provider.dart';
import '../providers/database_provider.dart';
import '../providers/task_detail_provider.dart';
import 'clarify_shared_widgets.dart';
import 'context_tag_picker.dart';
import 'process_to_handlers.dart';
import 'project_picker.dart';

/// Generic clarification card — see the library doc for the two shapes.
class ClarifyCard extends ConsumerStatefulWidget {
  /// Clarify an Inbox Capture into a new Outcome.
  const ClarifyCard.forCapture({
    super.key,
    required this.captureId,
    this.lastAction,
    this.onAfterRoute,
  }) : todoId = null;

  /// Re-clarify an Outcome that has already been through the flow once.
  const ClarifyCard.forOutcome({
    super.key,
    required this.todoId,
    this.lastAction,
    this.onAfterRoute,
  }) : captureId = null;

  /// The Capture being clarified, or null when re-clarifying an Outcome.
  final String? captureId;

  /// The Outcome being re-clarified, or null when clarifying a Capture.
  final String? todoId;

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

  /// True when this card is clarifying a Capture rather than re-clarifying an
  /// Outcome. Selects every save path below.
  bool get _isCapture => widget.captureId != null;

  /// The row id being edited — a Capture id or an Outcome id.
  String get _subjectId => widget.captureId ?? widget.todoId!;

  void _initialiseFrom({
    required String title,
    String? notes,
    String? energyLevel,
    int? timeEstimate,
    DateTime? dueDate,
  }) {
    if (_initialised) return;
    _initialised = true;
    _titleCtrl = TextEditingController(text: title);
    _notesCtrl = TextEditingController(text: notes ?? '');
    _lastSavedTitle = title.trim();
    _lastSavedNotes = (notes ?? '').trim();
    _titleIsBlank = title.trim().isEmpty;
    // A Capture carries none of these columns — they start empty and live as
    // draft state until the Outcome is created.
    _energyLevel = energyLevel;
    _timeEstimate = timeEstimate;
    _dueDate = dueDate?.toLocal();
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
      final db = ref.read(databaseProvider);
      final id = _subjectId;
      unawaited(
        _isCapture
            ? db.captureDao
                .updateFields(id, title: trimmedTitle, notes: trimmedNotes)
            : db.todoDao
                .updateFields(id, title: trimmedTitle, notes: trimmedNotes),
      );
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
    final id = _subjectId;
    if (_isCapture) {
      await db.captureDao
          .updateFields(id, title: trimmedTitle, notes: trimmedNotes);
    } else {
      await db.todoDao
          .updateFields(id, title: trimmedTitle, notes: trimmedNotes);
    }
    _lastSavedTitle = trimmedTitle;
    _lastSavedNotes = trimmedNotes;
  }

  // Energy / time estimate / due date are Outcome attributes with no column on
  // a Capture. On a Capture card the setState in the callsite *is* the save:
  // the value rides the draft into clarifyCaptureToOutcome. On an Outcome card
  // they autosave as before.

  Future<void> _saveEnergy(String? level) async {
    if (_isCapture || level == null) return;
    final db = ref.read(databaseProvider);
    await db.todoDao.updateFields(_subjectId, energyLevel: level);
  }

  Future<void> _saveTimeEstimate(int? minutes) async {
    if (_isCapture) return;
    final db = ref.read(databaseProvider);
    await db.todoDao.updateFields(
      _subjectId,
      timeEstimate: minutes,
      clearTimeEstimate: minutes == null,
    );
  }

  Future<void> _saveDueDate(DateTime? date, {required bool clear}) async {
    if (_isCapture) return;
    final db = ref.read(databaseProvider);
    await db.todoDao.updateFields(
      _subjectId,
      dueDate: date,
      clearDueDate: clear,
    );
  }

  // Tag edits on an Outcome route through [TaskDetailNotifier], which owns the
  // single-project invariant and user-scoped writes. None of these methods
  // touches `todos.intent` or person-tag join rows, so the intent ⊥ delegate
  // orthogonality invariant (ARCHITECTURE.md) is preserved structurally.
  // Unlike the person-tag methods, context/project edits deliberately do NOT
  // stamp `last_clarified_at` — the categorisation axes are not the clarified
  // moment (matches task_detail_screen behaviour).
  //
  // On a Capture the same edits persist as tag *hints* (`capture_tags`), which
  // seed the Outcome's tags at clarification. CaptureDao.assignProjectHint
  // enforces the same single-project invariant so a hint can't seed an Outcome
  // that violates it.
  TaskDetailNotifier get _tagNotifier =>
      ref.read(taskDetailNotifierProvider(_subjectId));

  Future<void> _saveAssignProject(String tagId) async {
    if (!_isCapture) return _tagNotifier.assignProject(tagId);
    final db = ref.read(databaseProvider);
    await db.captureDao.assignProjectHint(
      _subjectId,
      tagId,
      ref.read(currentUserIdProvider),
    );
  }

  Future<void> _saveClearProject() async {
    if (!_isCapture) return _tagNotifier.clearProject();
    await ref.read(databaseProvider).captureDao.clearProjectHint(_subjectId);
  }

  Future<void> _saveAssignContext(String tagId) async {
    if (!_isCapture) return _tagNotifier.assignContextTag(tagId);
    final db = ref.read(databaseProvider);
    await db.captureDao.assignTagHint(
      _subjectId,
      tagId,
      ref.read(currentUserIdProvider),
    );
  }

  Future<void> _saveRemoveContext(String tagId) async {
    if (!_isCapture) return _tagNotifier.removeContextTag(tagId);
    await ref.read(databaseProvider).captureDao.removeTagHint(_subjectId, tagId);
  }

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
    final captureId = widget.captureId;
    return captureId != null
        ? _buildForCapture(context, captureId)
        : _buildForOutcome(context, widget.todoId!);
  }

  Widget _buildForCapture(BuildContext context, String captureId) {
    final capture = ref.watch(captureProvider(captureId)).value;
    if (capture == null) {
      return const Center(child: CircularProgressIndicator());
    }
    // A Capture stores only title and notes; the rest of the card starts empty
    // and rides the draft into the Outcome.
    _initialiseFrom(title: capture.title, notes: capture.notes);

    final hints =
        ref.watch(captureTagHintsProvider(captureId)).asData?.value ??
            const <Tag>[];
    return _buildBody(
      context,
      tags: hints,
      subject: CaptureSubject(
        capture: capture,
        draft: () => _draft(hints),
      ),
    );
  }

  Widget _buildForOutcome(BuildContext context, String todoId) {
    final todo = ref.watch(taskDetailTodoProvider(todoId)).value;
    if (todo == null) {
      return const Center(child: CircularProgressIndicator());
    }
    _initialiseFrom(
      title: todo.title,
      notes: todo.notes,
      energyLevel: todo.energyLevel,
      timeEstimate: todo.timeEstimate,
      dueDate: todo.dueDate,
    );
    final tags =
        ref.watch(taskTagsProvider(todoId)).asData?.value ?? const <Tag>[];
    return _buildBody(context, tags: tags, subject: OutcomeSubject(todo));
  }

  /// Snapshot of the card's current state, read at tap time by
  /// [CaptureSubject.draft].
  ClarifyDraft _draft(List<Tag> hints) {
    final title = (_titleCtrl?.text ?? '').trim();
    final notes = (_notesCtrl?.text ?? '').trim();
    return ClarifyDraft(
      title: title,
      notes: notes.isEmpty ? null : notes,
      energyLevel: _energyLevel,
      timeEstimate: _timeEstimate,
      // Strip the time component: the picker collects a calendar day.
      dueDate: _dueDate != null
          ? DateTime(_dueDate!.year, _dueDate!.month, _dueDate!.day)
          : null,
      // Person tags never come from hints — the Waiting For picker supplies
      // those separately, and they are on the orthogonal delegation axis.
      tagIds: {
        for (final t in hints)
          if (t.type != 'person') t.id,
      },
      // Title-as-action coupling: a Capture is by definition a first
      // clarification, so there is no deliberate phrase to clobber and the
      // title always mirrors. applyRouting consumes this only for Next and
      // Waiting For, so the other destinations are unaffected.
      nextActionText: title.isEmpty ? null : title,
    );
  }

  Widget _buildBody(
    BuildContext context, {
    required List<Tag> tags,
    required ClarifySubject subject,
  }) {
    // Tags are watched live so the pickers re-render on DB change; keeping a
    // local mirror would go stale across the async write. Person tags are
    // intentionally excluded here — they are edited via the Waiting For
    // routing button (which opens PersonTagPickerSheet), never on this card.
    final allTags = tags;
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
          subject: subject,
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
            // Capture → the mirror travels in the draft (see [_draft]) and is
            //           applied by clarifyCaptureToOutcome as it creates the
            //           Outcome; there is nothing to write here.
            // Outcome → only mirror when `next_action_text` is null/empty;
            //           otherwise the user has already written a deliberate
            //           phrase and we must not clobber it.
            if (!_isCapture &&
                (action == ProcessAction.next ||
                    action == ProcessAction.waitingFor)) {
              final title = _titleCtrl?.text.trim() ?? '';
              if (title.isNotEmpty) {
                final db = ref.read(databaseProvider);
                final current = await db.todoDao.getTodo(_subjectId);
                if ((current?.nextActionText?.trim() ?? '').isEmpty) {
                  await db.todoDao.setNextActionText(_subjectId, title);
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
