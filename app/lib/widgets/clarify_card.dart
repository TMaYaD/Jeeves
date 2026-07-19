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
/// Both shapes bind to a live watch on their subject and render it through
/// [AsyncSubject], so a subject hard-deleted underneath the open card (sync
/// applying a remote delete) reaches a missing-item state with a way out
/// ([onSubjectMissing]) rather than an indefinite spinner.
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
import 'async_subject.dart';
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
    this.onSubjectMissing,
  }) : todoId = null;

  /// Re-clarify an Outcome that has already been through the flow once.
  const ClarifyCard.forOutcome({
    super.key,
    required this.todoId,
    this.lastAction,
    this.onAfterRoute,
    this.onSubjectMissing,
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

  /// The way out of the missing-subject state — invoked when the user taps the
  /// CTA on the card the subject vanished from under. Hosts wire this to
  /// whatever "move on" means for them: advancing the ceremony cursor, popping
  /// a pushed sub-flow route. When null the card renders the missing copy
  /// without a CTA, for hosts that already draw an escape outside the card.
  ///
  /// Deliberately *not* routed through [onAfterRoute]: that takes a
  /// [ProcessAction], and the only action meaning "no verdict" is
  /// `ProcessAction.keep`, whose `toRoutingKind()` is null — both ceremony
  /// callers early-return on null, so the cursor would silently never advance.
  final VoidCallback? onSubjectMissing;

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

  /// Tag-hint ids for the draft, on a Capture card.
  ///
  /// Seeded from the live hints on first build, then mutated **synchronously**
  /// by the picker callbacks. The DAO writes those callbacks fire are
  /// `unawaited`, and the hint stream needs a frame to come back, so a user who
  /// taps a destination immediately after touching a tag would otherwise route
  /// with the previous build's hints and lose the edit from the new Outcome.
  Set<String>? _draftTagIds;

  /// Whether [_draftTagIds] has been seeded from a *loaded* hint list. The
  /// provider's first emission is `loading`, which reads as an empty list —
  /// seeding from that would leave the draft permanently tagless.
  bool _draftTagsSeeded = false;

  static const _textDebounceMs = 400;
  Timer? _textDebouncer;
  String? _lastSavedTitle;
  String? _lastSavedNotes;

  /// True once the watched subject has emitted `AsyncData(null)` — the row was
  /// hard-deleted while this card was open (see [AsyncSubject]).
  ///
  /// Gates every text write. Without it a debounced autosave (or the
  /// `dispose()` flush) fires `updateFields` against a row that is gone: a
  /// harmless no-op under `NativeDatabase` in tests, but in production
  /// PowerSync queues the UPDATE, the backend 404s it, and it lands in
  /// `sync_dead_letters`.
  bool _subjectGone = false;

  /// Whether the missing-state escape has already been taken — see
  /// [_missingCta]. Safe to hold per-State: ceremonies key the card by subject
  /// id (`ClarifyStep`), so moving to the next item builds a fresh State and
  /// the latch resets with it.
  bool _missingEscapeFired = false;

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
    final hasPendingWrite = !_subjectGone &&
        trimmedTitle.isNotEmpty &&
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
    if (_subjectGone) return;
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
  //
  // Every autosave below opens with the [_subjectGone] guard, for the same
  // reason the text saves do. Losing the subject swaps the body for the
  // missing panel, so these controls leave the tree — but a *modal* opened
  // before the delete landed outlives that rebuild. Confirming a date in an
  // already-open `showDatePicker`, or a tag in an open picker sheet, would
  // otherwise write to a row that is gone: a no-op under `NativeDatabase`,
  // but in production a queued PowerSync UPDATE the backend 404s into
  // `sync_dead_letters`.

  Future<void> _saveEnergy(String? level) async {
    if (_isCapture || level == null || _subjectGone) return;
    final db = ref.read(databaseProvider);
    await db.todoDao.updateFields(_subjectId, energyLevel: level);
  }

  Future<void> _saveTimeEstimate(int? minutes) async {
    if (_isCapture || _subjectGone) return;
    final db = ref.read(databaseProvider);
    await db.todoDao.updateFields(
      _subjectId,
      timeEstimate: minutes,
      clearTimeEstimate: minutes == null,
    );
  }

  Future<void> _saveDueDate(DateTime? date, {required bool clear}) async {
    if (_isCapture || _subjectGone) return;
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
    if (_subjectGone) return;
    if (!_isCapture) return _tagNotifier.assignProject(tagId);
    final db = ref.read(databaseProvider);
    await db.captureDao.assignProjectHint(
      _subjectId,
      tagId,
      ref.read(currentUserIdProvider),
    );
  }

  Future<void> _saveClearProject() async {
    if (_subjectGone) return;
    if (!_isCapture) return _tagNotifier.clearProject();
    await ref.read(databaseProvider).captureDao.clearProjectHint(_subjectId);
  }

  Future<void> _saveAssignContext(String tagId) async {
    if (_subjectGone) return;
    if (!_isCapture) return _tagNotifier.assignContextTag(tagId);
    final db = ref.read(databaseProvider);
    await db.captureDao.assignTagHint(
      _subjectId,
      tagId,
      ref.read(currentUserIdProvider),
    );
  }

  Future<void> _saveRemoveContext(String tagId) async {
    if (_subjectGone) return;
    if (!_isCapture) return _tagNotifier.removeContextTag(tagId);
    await ref.read(databaseProvider).captureDao.removeTagHint(_subjectId, tagId);
  }

  // Draft tag bookkeeping — no-ops on an Outcome card, where tag edits are
  // written straight to `todo_tags` and there is no draft to keep in step.

  void _draftAdd(Tag t) {
    if (!_isCapture) return;
    setState(() => _draftTagIds = {...?_draftTagIds, t.id});
  }

  void _draftRemove(String tagId) {
    if (!_isCapture) return;
    setState(() => _draftTagIds = {...?_draftTagIds}..remove(tagId));
  }

  void _draftRemoveAll(List<Tag> tags) {
    if (!_isCapture) return;
    setState(() => _draftTagIds = {...?_draftTagIds}
      ..removeAll(tags.map((t) => t.id)));
  }

  /// Swap [t] in for whatever tags of the same axis are currently drafted —
  /// the single-project invariant, applied to the draft as well as the DB.
  void _draftReplaceOfType(Tag t, List<Tag> current) {
    if (!_isCapture) return;
    setState(() => _draftTagIds = {...?_draftTagIds}
      ..removeAll(current.map((c) => c.id))
      ..add(t.id));
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

  /// Latches [_subjectGone] off the watched subject and stops any pending
  /// autosave the moment the row disappears. Computed during build rather than
  /// via `setState` — it changes no rendering of its own, it only gates writes.
  ///
  /// The latch is **one-way**: a hard delete is terminal, since the row's id
  /// can never be reissued. Clearing the flag again on a later state that
  /// merely lacks a value (a disposed-and-recreated provider re-entering
  /// `AsyncLoading`) would reopen every write path against the dead row.
  void _trackSubjectPresence(AsyncValue<Object?> subject) {
    if (_subjectGone) return;
    if (!subject.isGone) return;
    _subjectGone = true;
    _textDebouncer?.cancel();
    _textDebouncer = null;
  }

  /// The card's escape from the missing-subject state, or null when the host
  /// draws its own (see [ClarifyCard.onSubjectMissing]).
  ///
  /// Fires at most once. The escape is not idempotent at any host — a ceremony
  /// advances its cursor, the re-clarify sub-flow pops its route — so a second
  /// activation before the first has torn the card down would skip an extra
  /// inbox item, or pop the *outer* review route out from under the user. The
  /// button stays enabled rather than greying out: the card is on its way out,
  /// and a disabled flash would be noise.
  Widget? get _missingCta {
    final onMissing = widget.onSubjectMissing;
    if (onMissing == null) return null;
    return FilledButton(
      onPressed: () {
        if (_missingEscapeFired) return;
        _missingEscapeFired = true;
        onMissing();
      },
      child: const Text('Continue'),
    );
  }

  Widget _buildForCapture(BuildContext context, String captureId) {
    final captureAsync = ref.watch(captureProvider(captureId));
    _trackSubjectPresence(captureAsync);
    return AsyncSubject<Capture>(
      asyncValue: captureAsync,
      missingIcon: Icons.inbox_outlined,
      missingTitle: 'This item is no longer in your Inbox',
      missingSubtitle: 'It may have been deleted on another device.',
      missingCta: _missingCta,
      dataBuilder: (context, capture) {
        // A Capture stores only title and notes; the rest of the card starts
        // empty and rides the draft into the Outcome.
        _initialiseFrom(title: capture.title, notes: capture.notes);

        final hintsAsync = ref.watch(captureTagHintsProvider(captureId));
        final hints = hintsAsync.asData?.value ?? const <Tag>[];
        if (hintsAsync.hasValue && !_draftTagsSeeded) {
          _draftTagsSeeded = true;
          // Person hints are excluded here, not merely screened later in
          // [_draft]. That screen compares against the *current* hint list, so
          // a person hint present at seed time but gone by routing time is no
          // longer recognised as one and rides the draft onto the Outcome —
          // which would leave a row routed to Next carrying a delegate it was
          // never delegated to (intent ⊥ delegate). Person hints are real:
          // the Nirvana migration copies a delegated todo's `todo_tags`
          // wholesale into `capture_tags`, and `watchTagHints` does not filter
          // by type. Keeping them out of the draft set makes the guarantee
          // structural rather than dependent on what the stream last emitted.
          _draftTagIds = {
            for (final t in hints)
              if (t.type != 'person') t.id,
          };
        }
        return _buildBody(
          context,
          tags: hints,
          // Settled means *resolved or failed*, not merely resolved. Hints
          // are a seeding nicety, not a precondition for clarifying, so a
          // hint watch that errors must degrade to "route without them"
          // rather than disabling the four Outcome routes for the life of the
          // card and stranding the user on an item they cannot process.
          // `InboxClarifyScreen` settles its flag in both the success and the
          // catch path for the same reason; this is the watch-shaped
          // equivalent. (Riverpod 3 delivers a stream error as loading
          // *carrying* an error, so `hasError` is the failure signal here.)
          hintsPending: !(hintsAsync.hasValue || hintsAsync.hasError),
          subject: CaptureSubject(
            capture: capture,
            draft: () => _draft(hints),
          ),
        );
      },
    );
  }

  Widget _buildForOutcome(BuildContext context, String todoId) {
    final todoAsync = ref.watch(taskDetailTodoProvider(todoId));
    _trackSubjectPresence(todoAsync);
    return AsyncSubject<Todo>(
      asyncValue: todoAsync,
      missingIcon: Icons.search_off,
      missingTitle: 'This outcome no longer exists',
      missingSubtitle: 'It may have been deleted on another device.',
      missingCta: _missingCta,
      dataBuilder: (context, todo) {
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
      },
    );
  }

  /// Snapshot of the card's current state, read at tap time by
  /// [CaptureSubject.draft].
  ClarifyDraft _draft(List<Tag> hints) {
    final title = (_titleCtrl?.text ?? '').trim();
    final notes = (_notesCtrl?.text ?? '').trim();
    final personHintIds = {
      for (final t in hints)
        if (t.type == 'person') t.id,
    };
    return ClarifyDraft(
      title: title,
      notes: notes.isEmpty ? null : notes,
      energyLevel: _energyLevel,
      timeEstimate: _timeEstimate,
      // Strip the time component: the picker collects a calendar day.
      dueDate: _dueDate != null
          ? DateTime(_dueDate!.year, _dueDate!.month, _dueDate!.day)
          : null,
      // The synchronous draft set once seeded, else whatever hints have
      // loaded. Person tags never travel this way — the Waiting For picker
      // supplies those, on the orthogonal delegation axis.
      tagIds: {
        for (final id in _draftTagsSeeded
            ? _draftTagIds ?? const <String>{}
            : {for (final t in hints) t.id})
          if (!personHintIds.contains(id)) id,
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
    // True while a Capture card's tag hints are still arriving. Outcome cards
    // leave it false: they have no hints to wait for.
    bool hintsPending = false,
  }) {
    // Tags are watched live so the pickers re-render on DB change; keeping a
    // local mirror would go stale across the async write. Person tags are
    // intentionally excluded here — they are edited via the Waiting For
    // routing button (which opens PersonTagPickerSheet), never on this card.
    final allTags = tags;
    final projectTags = allTags.where((t) => t.type == 'project').toList();
    final projectTag = projectTags.isEmpty ? null : projectTags.first;
    final contextTags = allTags.where((t) => t.type == 'context').toList();

    // Gated twice, for two reasons that both come down to what an Outcome must
    // carry. A title, because an Outcome must be nameable. And settled tag
    // hints, because they ride the draft into `clarifyCaptureToOutcome` — a tap
    // landing while they are still arriving reads the *currently emitted* list,
    // which is empty, and mints an Outcome missing every tag the Capture had,
    // silently. `InboxClarifyScreen` gates the same four routes on the same
    // hazard; this is the ceremony surface's half of it.
    //
    // Trash stays enabled through both: it creates no Outcome, so it needs
    // neither a name nor tags — an unnamed fragment is exactly what a user
    // wants to throw away.
    final disabled = (_titleIsBlank || hintsPending)
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
          onAssign: (t) {
            _draftReplaceOfType(t, projectTags);
            unawaited(_saveAssignProject(t.id));
          },
          onClear: () {
            _draftRemoveAll(projectTags);
            unawaited(_saveClearProject());
          },
        ),
        const SizedBox(height: 12),
        // Context row — multi-select; reuse ContextTagPickerWidget. Its
        // "+ context" trailing affordance doubles as the optional-tag hint.
        ContextTagPickerWidget(
          assignedTags: contextTags,
          onAssign: (t) {
            _draftAdd(t);
            unawaited(_saveAssignContext(t.id));
          },
          onRemove: (t) {
            _draftRemove(t.id);
            unawaited(_saveRemoveContext(t.id));
          },
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
              if (title.isNotEmpty && !_subjectGone) {
                final db = ref.read(databaseProvider);
                final current = await db.todoDao.getTodo(_subjectId);
                // A deleted row reads as `null`, which `?? ''` would flatten
                // into "no deliberate phrase to protect" — the one condition
                // that *permits* the write. So absence is checked explicitly,
                // or the mirror fires precisely on the rows it must not touch.
                // `_subjectGone` is re-tested because the delete can land
                // during the read above. Guarded rather than returned early:
                // `onAfterRoute` below still has to run, or the ceremony
                // cursor never advances.
                if (current != null &&
                    !_subjectGone &&
                    (current.nextActionText?.trim() ?? '').isEmpty) {
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
