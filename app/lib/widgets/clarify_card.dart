/// Generic clarification card. Renders an editable view of a Capture or an
/// Outcome plus the canonical [ProcessToHandlers] action bar.
///
/// Two shapes, matching the ADR-0006 split:
///
/// - [ClarifyCard.forCapture] — an Inbox Capture on its first pass through the
///   flow. **Nothing the user types is written to the Capture** (ADR-0023): a
///   Capture is the raw record of what was captured, and clarification
///   produces structure from it rather than editing it. Title and notes seed
///   from the row and feed the draft that
///   [ClarificationService.clarifyCaptureToOutcome] mints an Outcome from.
///   Energy, time estimate and due date have **no column on a Capture** (they
///   are Outcome attributes) and ride the same draft. Tag edits are the one
///   exception: they persist immediately as *tag hints* (`capture_tags`),
///   which seed that Outcome's tags — a hint is a suggestion recorded
///   alongside the fragment, not a rewrite of it.
/// - [ClarifyCard.forOutcome] — the re-clarify sub-flow on an already
///   clarified Outcome. Editing an Outcome is ordinary editing, so title and
///   notes save on focus loss (as `task_detail_screen` and
///   `active_focus_screen` do) and everything else saves straight to `todos`
///   as it changes.
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
import 'clarify_retention.dart';
import 'clarify_shared_widgets.dart';
import 'meta_chip.dart' show formatMinutesLabel;
import 'context_tag_picker.dart';
import 'process_to_handlers.dart';
import 'project_picker.dart';

/// Shown when the pre-verdict save of an Outcome's own text fails. The verdict
/// itself landed, so "try again" would be wrong advice — what is lost is the
/// last edit to the Outcome's title or notes, not the routing.
///
/// Has no Capture counterpart: a Capture's text is never written, so on that
/// shape there is no such failure to report (ADR-0023).
const _kTextSaveFailedMessage =
    'Routed, but your latest edit to the text was not saved.';

/// Shown when the host's post-verdict hook fails (cursor advance, navigation).
/// Deliberately distinct from [_kTextSaveFailedMessage] so the two failures are
/// never mistaken for each other.
const _kFinishingUpFailedMessage =
    'Saved, but finishing up failed. Some details may not have been updated.';

/// What a clarify surface does with the subject's tags — and, inseparably, how
/// it reads them.
///
/// The two halves are fused on purpose. A surface that renders no chips has
/// nothing on screen for a live stream to keep in step, and subscribing to a
/// live drift query from a widget leaves a pending timer that hangs
/// `pumpAndSettle` (docs/TESTING.md). Splitting this into "render pickers?"
/// and "watch or read once?" would make "no pickers, live watch" writable,
/// and it is wrong in both directions.
enum ClarifyTagSection {
  /// Editable project and context pickers, whose edits persist immediately as
  /// tag hints. Requires a live subscription so the chips re-render on change.
  editablePickers,

  /// Render no tag section at all, and read the hints exactly once as draft
  /// input for the Outcome.
  draftInputOnly,
}

class ClarifyCard extends ConsumerStatefulWidget {
  /// Clarify an Inbox Capture into a new Outcome.
  const ClarifyCard.forCapture({
    super.key,
    required this.captureId,
    required this.tagSection,
    this.lastAction,
    this.onAfterRoute,
    this.onCaptureCompleted,
    this.retention,
    this.footer,
    this.missingCta,
    this.onProcessingChanged,
  }) : todoId = null;

  /// Re-clarify an Outcome that has already been through the flow once.
  const ClarifyCard.forOutcome({
    super.key,
    required this.todoId,
    this.lastAction,
    this.onAfterRoute,
  })  : captureId = null,
        onCaptureCompleted = null,
        // An Outcome's edits persist as they happen, so there is nothing to
        // retain. Fixed rather than offered, so "re-clarify with retention"
        // cannot be written.
        retention = null,
        // An Outcome's tags live in `todo_tags` and there are no *hints* to
        // consume as draft input, so `draftInputOnly` has no meaning on this
        // shape.
        tagSection = ClarifyTagSection.editablePickers,
        // The one host is [ReclarifyRoute], which owns its own chrome.
        footer = null,
        missingCta = null,
        onProcessingChanged = null;

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

  /// Where the in-progress draft is held while the user navigates away and
  /// back within a Ceremony performance. Null means no retention: leaving
  /// discards the typing.
  ///
  /// Passed in rather than looked up so the card can stash from `dispose()`,
  /// where `ref` is already unusable (#529) — and so a host that should not
  /// retain expresses that by passing nothing. The standalone
  /// `/inbox/:id/clarify` screen and the Re-clarify route both have exactly
  /// two exits, each a deliberate leave, so neither is given one.
  final ClarifyRetention? retention;

  /// Whether the card renders editable tag pickers, and how it reads the tags
  /// either way. Required on a Capture: the two live hosts genuinely differ,
  /// so a third must decide rather than inherit.
  final ClarifyTagSection tagSection;

  /// Rendered as the card's last child, below the PROCESS TO bar.
  ///
  /// The slot exists for affordances that are not routing verdicts — the
  /// standalone screen's Skip, which leaves `clarified_at` NULL and the
  /// Capture in the Inbox. The host builds it and owns its enabled state, so
  /// the card never learns what "Skip" means.
  final Widget? footer;

  /// The way out offered when the subject is gone from local storage.
  ///
  /// Hosts reached as their own route supply one — a pushed screen has no
  /// other exit once its fields are gone. The ceremony hosts pass none: their
  /// step footer already owns Skip, and a second exit there would offer to
  /// leave the whole ritual.
  final Widget? missingCta;

  /// Mirrors [ProcessToHandlers]' in-flight state outward, so a host can shut
  /// the escapes it owns — its own back button, a platform-back guard, the
  /// [footer] — alongside the bar's own buttons.
  ///
  /// The card reports; it never guards. Every exit belongs to a host, so the
  /// decision does too. Fires false from a `finally`, which can arrive after
  /// the host has unmounted — hosts must guard their own `setState`.
  final ValueChanged<bool>? onProcessingChanged;

  @override
  ConsumerState<ClarifyCard> createState() => _ClarifyCardState();
}

class _ClarifyCardState extends ConsumerState<ClarifyCard> {
  /// The database handle, captured while the element is still mounted so
  /// [dispose] can issue the Outcome shape's pending-edit flush.
  ///
  /// `dispose()` cannot reach it through `ref`: `StatefulElement.unmount()`
  /// calls `Element.unmount()` — which marks the element defunct, so
  /// `context.mounted` goes false — *before* it calls `state.dispose()`, and
  /// Riverpod's `ref` asserts on exactly that. Reading it there threw on the
  /// flush's first line and the edit was lost (#529). Every other read in this
  /// State runs while mounted and goes through `ref` as usual.
  late final GtdDatabase _databaseForDisposeFlush;

  TextEditingController? _titleCtrl;
  TextEditingController? _notesCtrl;

  /// Focus nodes for the two text fields. On the Outcome shape their listeners
  /// are the save trigger — the same focus-loss rule `task_detail_screen` and
  /// `active_focus_screen` use, so re-clarify does not behave differently from
  /// every other place an Outcome's text is edited (ADR-0023).
  ///
  /// On the Capture shape they carry no listener at all: there is nothing to
  /// save.
  final _titleFocusNode = FocusNode();
  final _notesFocusNode = FocusNode();

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

  /// True once this Capture has reached a verdict. Suppresses the retention
  /// stash in [dispose], which would otherwise reinstate the draft the verdict
  /// just discarded.
  bool _verdictReached = false;

  /// Whether the last build rendered the n-m surface, where the Capture is
  /// read-only and the card contributes no text fields.
  ///
  /// Read in [dispose] to skip the stash: there is nothing on screen to
  /// retain, and stashing the untouched seed would overwrite a real draft left
  /// by a 1-1 pass. Tracked from the build rather than assumed constant
  /// because `clarifyModeProvider` is a synced preference that can flip while
  /// the card is open.
  bool _renderedNToM = false;

  /// The Capture's tag hints under [ClarifyTagSection.draftInputOnly], read
  /// once in [initState].
  ///
  /// They seed the new Outcome's tags through the draft — minus the person
  /// hints, which [ClarifyDraft.assemble] drops. Failing to read them costs
  /// the user their hints, not their clarification, so a failure leaves the
  /// card usable with an empty list rather than tearing it down: the subject
  /// the card renders comes from elsewhere.
  List<Tag> _oneShotHints = const <Tag>[];

  /// The subject values the card's fields were last reconciled against —
  /// seeded from the row, or written back to it.
  ///
  /// They are the clean/dirty markers the live binding reconciles against: a
  /// field still matching its baseline is clean, so an incoming change may be
  /// applied to it; anything else is an edit in progress and is left alone.
  /// On the Outcome shape they also suppress redundant writes.
  String? _baselineTitle;
  String? _baselineNotes;
  String? _baselineEnergy;
  int? _baselineTimeEstimate;
  DateTime? _baselineDueDate;

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
    // On a Capture with a retention store, the seed is the reconciliation of
    // the retained draft against this row — see [RetainedClarifyDraft.seedFrom]
    // for the per-field rule. With no store, or on an Outcome, `seedFrom(null)`
    // is exactly "take the row", which is what every surface did before
    // retention existed.
    final seed = RetainedClarifyDraft.seedFrom(
      _isCapture ? widget.retention?.read(_subjectId) : null,
      incomingTitle: title,
      incomingNotes: notes,
    );
    _titleCtrl = TextEditingController(text: seed.title);
    _notesCtrl = TextEditingController(text: seed.notes);
    _baselineTitle = seed.baselineTitle;
    _baselineNotes = seed.baselineNotes;
    _titleIsBlank = seed.title.trim().isEmpty;
    // A Capture carries none of these columns — they start empty (or from the
    // retained draft) and live as draft state until the Outcome is created.
    _energyLevel = seed.energyLevel ?? energyLevel;
    _timeEstimate = seed.timeEstimateMinutes ?? timeEstimate;
    _dueDate = seed.dueDate ?? dueDate?.toLocal();
    _baselineEnergy = _energyLevel;
    _baselineTimeEstimate = _timeEstimate;
    _baselineDueDate = _dueDate;
  }

  /// The card's current text and draft attributes, with the baselines they
  /// were typed against, ready to hand to the retention store.
  RetainedClarifyDraft _retainable() => RetainedClarifyDraft(
        title: _titleCtrl?.text ?? '',
        notes: _notesCtrl?.text ?? '',
        baselineTitle: _baselineTitle,
        baselineNotes: _baselineNotes,
        energyLevel: _energyLevel,
        timeEstimateMinutes: _timeEstimate,
        dueDate: _dueDate,
      );

  /// Drops this Capture's retained draft: the verdict has landed, so the
  /// interpretation now lives on an Outcome (or the fragment was discarded)
  /// and there is nothing left to carry.
  ///
  /// Also latches [_verdictReached] so the stash in [dispose] — which runs
  /// moments later, as the host advances its cursor — cannot put the spent
  /// draft straight back.
  void _discardRetainedDraft() {
    if (!_isCapture) return;
    _verdictReached = true;
    widget.retention?.discard(_subjectId);
  }

  /// Reconciles the card with the subject as local storage now holds it,
  /// applying each incoming value only to a field that is still clean (see
  /// [_baselineTitle]).
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
    if ((_titleCtrl?.text ?? '').trim() == _baselineTitle &&
        trimmedTitle != _baselineTitle) {
      _titleCtrl?.text = title;
      _baselineTitle = trimmedTitle;
      _titleIsBlank = trimmedTitle.isEmpty;
      changed = true;
    }
    final trimmedNotes = (notes ?? '').trim();
    if ((_notesCtrl?.text ?? '').trim() == _baselineNotes &&
        trimmedNotes != _baselineNotes) {
      _notesCtrl?.text = notes ?? '';
      _baselineNotes = trimmedNotes;
      changed = true;
    }
    if (_isCapture) {
      if (changed) setState(() {});
      return;
    }
    if (_energyLevel == _baselineEnergy && energyLevel != _baselineEnergy) {
      _energyLevel = energyLevel;
      _baselineEnergy = energyLevel;
      changed = true;
    }
    if (_timeEstimate == _baselineTimeEstimate &&
        timeEstimate != _baselineTimeEstimate) {
      _timeEstimate = timeEstimate;
      _baselineTimeEstimate = timeEstimate;
      changed = true;
    }
    final incomingDue = dueDate?.toLocal();
    if (_dueDate == _baselineDueDate && incomingDue != _baselineDueDate) {
      _dueDate = incomingDue;
      _baselineDueDate = incomingDue;
      changed = true;
    }
    if (changed) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _databaseForDisposeFlush = ref.read(databaseProvider);
    if (_isCapture && widget.tagSection == ClarifyTagSection.draftInputOnly) {
      unawaited(_loadOneShotHints());
    }
    if (!_isCapture) {
      // Focus loss is the Outcome shape's save trigger. A Capture's text is
      // never written, so it gets no listener — the absence is the rule
      // (ADR-0023), not a branch inside a shared handler.
      _titleFocusNode.addListener(_onFocusChanged);
      _notesFocusNode.addListener(_onFocusChanged);
    }
  }

  /// Reads the tag hints that seed the new Outcome's tags — see
  /// [_oneShotHints] for why a failure is swallowed.
  Future<void> _loadOneShotHints() async {
    final List<Tag> hints;
    try {
      hints = await ref
          .read(databaseProvider)
          .captureDao
          .tagHintsForCapture(_subjectId);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    setState(() => _oneShotHints = hints);
  }

  void _onFocusChanged() {
    if (_titleFocusNode.hasFocus || _notesFocusNode.hasFocus) return;
    if (!mounted) return;
    unawaited(_saveOutcomeText());
  }

  @override
  void dispose() {
    // Stash the in-progress draft so Back within a Ceremony performance finds
    // it again. Synchronous, and through the injected store rather than `ref`,
    // which is already unusable here (#529).
    //
    // Skipped once a verdict has landed (the draft is spent) and in n-m, where
    // the card renders no text fields and would stash a seed over a real
    // draft.
    if (_isCapture && _initialised && !_verdictReached && !_renderedNToM) {
      widget.retention?.stash(_subjectId, _retainable());
    }
    // The Outcome shape's last line of defence: leaving the card while a field
    // still holds focus (a route pop tears the focus scope down without
    // notifying this listener first) would otherwise drop the edit.
    //
    // A Capture takes no such path — nothing it holds is ever written — so
    // this whole block is Outcome-only, and with it goes the `ref`-in-dispose
    // hazard on the Capture side (#529).
    if (!_isCapture) {
      // Snapshot pending edits up-front so the fire-and-forget write below
      // doesn't touch disposed controllers or assign back into a disposed
      // State. The database handle comes from [_databaseForDisposeFlush]
      // rather than `ref`, which is already unusable by the time this runs —
      // see that field.
      final trimmedTitle = (_titleCtrl?.text ?? '').trim();
      final trimmedNotes = (_notesCtrl?.text ?? '').trim();
      final hasPendingWrite = trimmedTitle.isNotEmpty &&
          (trimmedTitle != _baselineTitle || trimmedNotes != _baselineNotes);
      if (hasPendingWrite) {
        unawaited(
          _databaseForDisposeFlush.todoDao.updateFields(
            _subjectId,
            title: trimmedTitle,
            // Same clear-flag contract as [_saveOutcomeText]: an emptied field
            // nulls the column rather than storing `''`.
            notes: trimmedNotes.isNotEmpty ? trimmedNotes : null,
            clearNotes: trimmedNotes.isEmpty,
          ),
        );
      }
    }
    _titleFocusNode.dispose();
    _notesFocusNode.dispose();
    _titleCtrl?.dispose();
    _notesCtrl?.dispose();
    super.dispose();
  }

  /// Keeps the blank-title gate in step as the user types.
  ///
  /// Nothing else happens here on either shape: a Capture is never written,
  /// and an Outcome saves on focus loss rather than on a timer.
  void _onTextChanged() {
    final blank = (_titleCtrl?.text ?? '').trim().isEmpty;
    if (blank != _titleIsBlank) {
      setState(() => _titleIsBlank = blank);
    }
  }

  /// Writes the *Outcome's* title and notes. Never called on a Capture, which
  /// has no text write at all (ADR-0023).
  Future<void> _saveOutcomeText() async {
    if (_isCapture) return;
    final trimmedTitle = (_titleCtrl?.text ?? '').trim();
    final trimmedNotes = (_notesCtrl?.text ?? '').trim();
    // An Outcome must stay nameable, so a blank title is not a save — the
    // routing buttons are disabled in that state and the field carries its own
    // error text.
    if (trimmedTitle.isEmpty) return;
    if (trimmedTitle == _baselineTitle && trimmedNotes == _baselineNotes) {
      return;
    }
    // An emptied notes field must null the column, not store `''`: every
    // `notes == null` read treats an empty string as "has notes". `null` is
    // "no change" to the DAO, so clearing has to travel as the clear flag.
    await ref.read(databaseProvider).todoDao.updateFields(
          _subjectId,
          title: trimmedTitle,
          notes: trimmedNotes.isNotEmpty ? trimmedNotes : null,
          clearNotes: trimmedNotes.isEmpty,
        );
    _baselineTitle = trimmedTitle;
    _baselineNotes = trimmedNotes;
  }

  // Energy / time estimate / due date are Outcome attributes with no column on
  // a Capture. On a Capture card the setState in the callsite *is* the save:
  // the value rides the draft into clarifyCaptureToOutcome (and, between
  // mounts, the retention store). On an Outcome card they save immediately —
  // they are the Outcome's own attributes, not the provenance record ADR-0023
  // protects.

  Future<void> _saveEnergy(String? level) async {
    if (_isCapture) return;
    // `null` means "no change" to the DAO, so deselecting has to say so with
    // the clear flag — otherwise the write is a silent no-op and, worse,
    // `_baselineEnergy` would drift away from the column and leave the field
    // permanently dirty to `_adoptFromSubject`.
    _baselineEnergy = level;
    final db = ref.read(databaseProvider);
    await db.todoDao.updateFields(
      _subjectId,
      energyLevel: level,
      clearEnergyLevel: level == null,
    );
  }

  Future<void> _saveTimeEstimate(int? minutes) async {
    if (_isCapture) return;
    _baselineTimeEstimate = minutes;
    final db = ref.read(databaseProvider);
    await db.todoDao.updateFields(
      _subjectId,
      timeEstimate: minutes,
      clearTimeEstimate: minutes == null,
    );
  }

  Future<void> _saveDueDate(DateTime? date, {required bool clear}) async {
    if (_isCapture) return;
    _baselineDueDate = date;
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
      missingBuilder: (_) => ClarifySubjectMissing(cta: widget.missingCta),
      dataBuilder: (context, capture) {
        // A Capture stores only title and notes; the rest of the card starts
        // empty and rides the draft into the Outcome.
        _initialiseFrom(title: capture.title, notes: capture.notes);

        final List<Tag> hints;
        if (widget.tagSection == ClarifyTagSection.editablePickers) {
          final hintsAsync = ref.watch(captureTagHintsProvider(captureId));
          hints = hintsAsync.asData?.value ?? const <Tag>[];
          if (hintsAsync.hasValue && !_draftTagsSeeded) {
            _draftTagsSeeded = true;
            _draftTagIds = {for (final t in hints) t.id};
          }
        } else {
          // draftInputOnly: the one-shot read from [initState]. Deliberately
          // no `ref.watch` of the hint provider — see [ClarifyTagSection].
          hints = _oneShotHints;
        }
        _renderedNToM = ref.watch(clarifyModeProvider) == ClarifyMode.nToM;
        if (_renderedNToM) {
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
      // `missingCta` is fixed null on this shape — [ReclarifyRoute] is the one
      // host and its app bar is the way back.
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
  /// [CaptureSubject.draft]. The assembly rules themselves live in
  /// [ClarifyDraft.assemble]; this method only supplies the field state.
  ClarifyDraft _draft(List<Tag> hints) => ClarifyDraft.assemble(
        title: _titleCtrl?.text ?? '',
        notes: _notesCtrl?.text ?? '',
        dueDate: _dueDate,
        hintTags: hints,
        // The synchronous draft once seeded, else null so the loaded hints
        // stand in for it.
        draftTagIds: _draftTagsSeeded ? _draftTagIds ?? const <String>{} : null,
        energyLevel: _energyLevel,
        timeEstimateMinutes: _timeEstimate,
      );

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
          focusNode: _titleFocusNode,
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
          focusNode: _notesFocusNode,
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

        if (widget.tagSection == ClarifyTagSection.editablePickers) ...[
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
        ],

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
          children: kEstimateOptionsMinutes.map((m) {
            final selected = _timeEstimate == m;
            return ClarifyEstimateChip(
              label: formatMinutesLabel(m),
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
          onAfterRoute: _onAfterRoute,
          onProcessingChanged: widget.onProcessingChanged,
        ),
        if (widget.footer != null) ...[
          const SizedBox(height: 20),
          widget.footer!,
        ],
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
        // The footer survives into n-m unchanged: leaving mid-split is exactly
        // what that mode is for — the Capture keeps whatever Outcomes it has
        // carved so far and stays in the Inbox.
        if (widget.footer != null) ...[
          const SizedBox(height: 20),
          widget.footer!,
        ],
      ],
    );
  }

  /// Post-routing bookkeeping, with each half on its own error boundary.
  ///
  /// The routing verdict has already landed by the time this runs. Saving the
  /// Outcome's own text is a *different* event from the host failing to
  /// advance its cursor, and collapsing them would let one hide the other —
  /// the host would never be told, or the save failure would be blamed on the
  /// host. Each is reported where it happens and neither aborts the other.
  ///
  /// On a Capture the first half does not exist: nothing it holds is written.
  Future<void> _onAfterRoute(ProcessAction action) async {
    // The verdict has landed: the interpretation now lives on the Outcome the
    // routing minted (or the fragment was discarded), so the retained draft is
    // spent.
    _discardRetainedDraft();
    if (!_isCapture) {
      try {
        // Tapping a destination does not move focus, so the focus-loss trigger
        // has not fired for an edit made right up to the tap. Save it before
        // yielding — and before the mirror below reads the title.
        await _saveOutcomeText();
        // Title-as-action coupling: when the user routes to Next or Waiting
        // For from a clarify card, mirror the current title into the Action so
        // the row leaves with a defined one. With the dialog modifier
        // excepted, Next reports plain `next`.
        //
        // Only mirror when the Outcome is Actionless (no `current` Action
        // row); otherwise the user has already written a deliberate phrase and
        // we must not clobber it. The Action entity is the evidence, not the
        // cursor (ADR-0001 story 3).
        //
        // On a Capture the mirror travels in the draft (see [_draft]) and is
        // applied by clarifyCaptureToOutcome as it creates the Outcome, so
        // there is nothing to write here either.
        if (action == ProcessAction.next ||
            action == ProcessAction.waitingFor) {
          final title = _titleCtrl?.text.trim() ?? '';
          if (title.isNotEmpty) {
            // One atomic call: the actionless check and the mirror write share
            // a transaction, so a `current` Action landed by sync between the
            // two can no longer be clobbered (issue #501).
            await ref
                .read(databaseProvider)
                .todoDao
                .setNextActionTextIfActionless(_subjectId, title);
          }
        }
      } catch (_) {
        _report(_kTextSaveFailedMessage);
      }
    }
    try {
      await widget.onAfterRoute?.call(action);
    } catch (_) {
      _report(_kFinishingUpFailedMessage);
    }
  }

  /// Post-verdict bookkeeping for the n-m surface. Same two-boundary
  /// discipline as [_onAfterRoute], with only the host half to run: the n-m
  /// surface is Capture-only and a Capture's text is never written.
  Future<void> _onCaptureCompleted() async {
    _discardRetainedDraft();
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
