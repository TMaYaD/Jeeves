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
/// Either shape binds to its subject live — [captureProvider] /
/// [taskDetailTodoProvider] — so a row that changes, or disappears, while the
/// card is open re-renders it. Incoming changes are applied only to fields the
/// user has not locally dirtied; an edit in progress always wins. This is
/// local-storage reactivity: the card cannot tell whether a change came from
/// another screen, a background job or a replicated write, and does not try
/// (ARCHITECTURE.md § Sync Engine — the UI's contract is with the local row).
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
import '../models/clarify_mode.dart';
import '../providers/auth_provider.dart';
import '../providers/clarify_mode_provider.dart';
import '../providers/database_provider.dart';
import '../providers/task_detail_provider.dart';
import 'async_subject.dart';
import 'capture_outcomes_section.dart';
import 'clarify_shared_widgets.dart';
import 'context_tag_picker.dart';
import 'process_to_handlers.dart';
import 'project_picker.dart';

/// Generic clarification card — see the library doc for the two shapes.
/// Shown when the post-verdict text flush fails. The verdict itself landed,
/// so "try again" would be wrong advice — what is lost is the last edit to the
/// Capture's own text, not the clarification.
const _kFlushFailedMessage =
    'Saved, but your latest edit to the Capture text was not.';

/// Shown when the host's post-verdict hook fails (cursor advance, navigation).
/// Deliberately distinct from [_kFlushFailedMessage] so the two failures are
/// never mistaken for each other.
const _kFinishingUpFailedMessage =
    'Saved, but finishing up failed. Some details may not have been updated.';

class ClarifyCard extends ConsumerStatefulWidget {
  /// Clarify an Inbox Capture into a new Outcome.
  const ClarifyCard.forCapture({
    super.key,
    required this.captureId,
    this.lastAction,
    this.onAfterRoute,
    this.onCaptureCompleted,
  }) : todoId = null;

  /// Re-clarify an Outcome that has already been through the flow once.
  const ClarifyCard.forOutcome({
    super.key,
    required this.todoId,
    this.lastAction,
    this.onAfterRoute,
  })  : captureId = null,
        onCaptureCompleted = null;

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

  /// Called once after the n-m verdict lands (Done-with-this-Capture or
  /// Discard). Separate from [onAfterRoute] because the n-m verdict is not a
  /// routing decision: no destination was chosen, so there is no
  /// [ProcessAction] to report and nothing for a host to record as the
  /// item's routing. Hosts that only need to advance a cursor wire both.
  final Future<void> Function()? onCaptureCompleted;

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

  /// The subject values the card last put into its fields — seeded from the
  /// row, or saved back to it.
  ///
  /// They serve double duty: they suppress redundant writes, and they are the
  /// clean/dirty markers the live binding reconciles against. A field still
  /// matching its marker is clean, so an incoming change may be applied to it;
  /// anything else is an edit in progress and is left alone.
  String? _lastSavedTitle;
  String? _lastSavedNotes;
  String? _lastSavedEnergy;
  int? _lastSavedTimeEstimate;
  DateTime? _lastSavedDueDate;

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
    _lastSavedEnergy = _energyLevel;
    _lastSavedTimeEstimate = _timeEstimate;
    _lastSavedDueDate = _dueDate;
  }

  /// Reconciles the card with the subject as local storage now holds it,
  /// applying each incoming value only to a field that is still clean (see
  /// [_lastSavedTitle]).
  ///
  /// Energy, estimate and due date have no column on a Capture, so on that
  /// shape they are draft state with nothing to reconcile against and the
  /// incoming values are ignored.
  void _adoptFromSubject({
    required String title,
    String? notes,
    String? energyLevel,
    int? timeEstimate,
    DateTime? dueDate,
  }) {
    if (!mounted || !_initialised) return;
    var changed = false;
    final trimmedTitle = title.trim();
    if ((_titleCtrl?.text ?? '').trim() == _lastSavedTitle &&
        trimmedTitle != _lastSavedTitle) {
      _titleCtrl?.text = title;
      _lastSavedTitle = trimmedTitle;
      _titleIsBlank = trimmedTitle.isEmpty;
      changed = true;
    }
    final trimmedNotes = (notes ?? '').trim();
    if ((_notesCtrl?.text ?? '').trim() == _lastSavedNotes &&
        trimmedNotes != _lastSavedNotes) {
      _notesCtrl?.text = notes ?? '';
      _lastSavedNotes = trimmedNotes;
      changed = true;
    }
    if (_isCapture) {
      if (changed) setState(() {});
      return;
    }
    if (_energyLevel == _lastSavedEnergy && energyLevel != _lastSavedEnergy) {
      _energyLevel = energyLevel;
      _lastSavedEnergy = energyLevel;
      changed = true;
    }
    if (_timeEstimate == _lastSavedTimeEstimate &&
        timeEstimate != _lastSavedTimeEstimate) {
      _timeEstimate = timeEstimate;
      _lastSavedTimeEstimate = timeEstimate;
      changed = true;
    }
    final incomingDue = dueDate?.toLocal();
    if (_dueDate == _lastSavedDueDate && incomingDue != _lastSavedDueDate) {
      _dueDate = incomingDue;
      _lastSavedDueDate = incomingDue;
      changed = true;
    }
    if (changed) setState(() {});
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
    _lastSavedEnergy = level;
    final db = ref.read(databaseProvider);
    await db.todoDao.updateFields(_subjectId, energyLevel: level);
  }

  Future<void> _saveTimeEstimate(int? minutes) async {
    if (_isCapture) return;
    _lastSavedTimeEstimate = minutes;
    final db = ref.read(databaseProvider);
    await db.todoDao.updateFields(
      _subjectId,
      timeEstimate: minutes,
      clearTimeEstimate: minutes == null,
    );
  }

  Future<void> _saveDueDate(DateTime? date, {required bool clear}) async {
    if (_isCapture) return;
    _lastSavedDueDate = date;
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

  Widget _buildForCapture(BuildContext context, String captureId) {
    // Reconcile from the listener rather than from the build itself: applying
    // a change writes into the controllers, and a controller that notifies its
    // TextField mid-build would rebuild a widget that is already building.
    ref.listen<AsyncValue<Capture?>>(captureProvider(captureId), (_, next) {
      final incoming = next.value;
      if (incoming == null) return;
      _adoptFromSubject(title: incoming.title, notes: incoming.notes);
    });
    return AsyncSubject<Capture>(
      asyncValue: ref.watch(captureProvider(captureId)),
      missingTitle: 'This item is no longer here',
      // The card is always embedded — in a ceremony step, or in the reclarify
      // route — and its host owns the exit, so it supplies no CTA of its own.
      missingBuilder: (_) => const ClarifySubjectMissing(),
      dataBuilder: (context, capture) {
        // A Capture stores only title and notes; the rest of the card starts
        // empty and rides the draft into the Outcome.
        _initialiseFrom(title: capture.title, notes: capture.notes);

        final hintsAsync = ref.watch(captureTagHintsProvider(captureId));
        final hints = hintsAsync.asData?.value ?? const <Tag>[];
        if (hintsAsync.hasValue && !_draftTagsSeeded) {
          _draftTagsSeeded = true;
          _draftTagIds = {for (final t in hints) t.id};
        }
        if (ref.watch(clarifyModeProvider) == ClarifyMode.nToM) {
          return _buildNToM(capture, hints);
        }
        return _buildBody(
          context,
          tags: hints,
          subject: CaptureSubject(
            capture: capture,
            draft: () => _draft(hints),
          ),
        );
      },
    );
  }

  Widget _buildForOutcome(BuildContext context, String todoId) {
    // See [_buildForCapture] for why reconciliation happens in the listener.
    ref.listen<AsyncValue<Todo?>>(taskDetailTodoProvider(todoId), (_, next) {
      final incoming = next.value;
      if (incoming == null) return;
      _adoptFromSubject(
        title: incoming.title,
        notes: incoming.notes,
        energyLevel: incoming.energyLevel,
        timeEstimate: incoming.timeEstimate,
        dueDate: incoming.dueDate,
      );
    });
    return AsyncSubject<Todo>(
      asyncValue: ref.watch(taskDetailTodoProvider(todoId)),
      missingTitle: 'This item is no longer here',
      missingBuilder: (_) => const ClarifySubjectMissing(),
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
        // No current-Action text: this card excepts the `nextActionDialog`
        // modifier (the title-as-action coupling below supplies the phrase
        // instead), so nothing here reads it.
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
    // committed routes; Trash stays enabled so the user can throw away an
    // unnamed item.
    final disabled = _titleIsBlank
        ? <ProcessAction>{
            ProcessAction.next,
            ProcessAction.waitingFor,
            ProcessAction.someday,
            if (!_isCapture) ProcessAction.done,
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
            borderRadius: BorderRadius.circular(6),
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
          key: const Key('clarify_title'),
          controller: _titleCtrl,
          onChanged: (_) => _onTextChanged(),
          decoration: InputDecoration(
            labelText: 'Title',
            errorText: _titleIsBlank ? 'Title is required to process' : null,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          textCapitalization: TextCapitalization.sentences,
          maxLines: 2,
          minLines: 1,
        ),
        const SizedBox(height: 12),

        TextField(
          key: const Key('clarify_notes'),
          controller: _notesCtrl,
          onChanged: (_) => _onTextChanged(),
          decoration: InputDecoration(
            labelText: 'Notes (optional)',
            hintText: 'Context, desired outcome, dependencies…',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
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
          // On a Capture, Done is not a clarify-time destination — an Outcome
          // captured already-complete is a contradiction, and completing one
          // belongs on its own surface. Trash stays as the Capture-level
          // Discard verdict in the slot Done vacates. Re-clarifying an
          // *Outcome* keeps Done: there the row exists and finishing it is a
          // real verdict.
          //
          // Also opt out of the default-on `nextActionDialog` modifier: the
          // clarify card supplies the phrase via the title-as-action coupling
          // below, so tapping Next routes immediately rather than popping the
          // dialog.
          except: {
            ProcessAction.nextActionDialog,
            if (_isCapture) ProcessAction.done,
          },
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
            // Outcome → only mirror when the Outcome is Actionless (no
            //           `current` Action row); otherwise the user has already
            //           written a deliberate phrase and we must not clobber
            //           it. The Action entity is the evidence, not the cursor
            //           (ADR-0001 story 3).
            if (!_isCapture &&
                (action == ProcessAction.next ||
                    action == ProcessAction.waitingFor)) {
              final title = _titleCtrl?.text.trim() ?? '';
              if (title.isNotEmpty) {
                final db = ref.read(databaseProvider);
                // One atomic call: the actionless check and the mirror write
                // share a transaction, so a `current` Action landed by sync
                // between the two can no longer be clobbered (issue #501).
                await db.todoDao
                    .setNextActionTextIfActionless(_subjectId, title);
              }
            }
            await widget.onAfterRoute?.call(action);
          },
        ),
      ],
    );
  }

  /// The n-m Capture body: the Capture read-only, the Outcomes it has yielded,
  /// the inline New Outcome form and the verdict — all of it owned by
  /// [CaptureOutcomesSection]. The card contributes no fields of its own in
  /// that mode, because in n-m the Capture is provenance and the *Outcome* is
  /// what the fields describe.
  Widget _buildNToM(Capture capture, List<Tag> hints) {
    return ListView(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        CaptureOutcomesSection(
          capture: capture,
          tagIds: _draft(hints).tagIds,
          onCompleted: _onCaptureCompleted,
        ),
      ],
    );
  }

  /// Post-verdict bookkeeping, with the two halves on their own error
  /// boundaries.
  ///
  /// The verdict has already landed by the time this runs. A failure to flush
  /// the card's text is a *different* event from the host failing to advance
  /// its cursor, and collapsing them would let one hide the other — the host
  /// would never be told, or the flush failure would be blamed on the host.
  /// Each is reported where it happens and neither aborts the other.
  Future<void> _onCaptureCompleted() async {
    try {
      await _flushTextSave();
    } catch (_) {
      _report(_kFlushFailedMessage);
    }
    try {
      await widget.onCaptureCompleted?.call();
    } catch (_) {
      _report(_kFinishingUpFailedMessage);
    }
  }

  void _report(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}
