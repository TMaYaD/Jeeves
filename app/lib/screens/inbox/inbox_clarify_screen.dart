/// Standalone clarify screen for a single Inbox Capture.
///
/// Opened when the user taps an inbox row outside of a planning session. It
/// binds to its Capture live and pops once the item is clarified, but the
/// routing verdict itself is not its own: the action bar is
/// [ProcessToHandlers], the same widget every ceremony clarify surface
/// renders, so the destinations, their copy and the writes behind them cannot
/// drift from those surfaces.
///
/// Title and notes are saved onto the Capture after a successful route.
/// Energy, time estimate and due date have no column on a Capture (ADR-0006) —
/// they are held as draft state here and ride the [ClarifyDraft] into the
/// Outcome that [ClarificationService.clarifyCaptureToOutcome] creates.
///
/// The subject comes from [captureProvider], so a row that changes — or
/// disappears — while the screen is open re-renders it. That is local-storage
/// reactivity and nothing more: the screen has no way to tell whether a change
/// came from another screen, a background job or a replicated write, and does
/// not try (ARCHITECTURE.md § Sync Engine — the UI's contract is with the local row).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../database/gtd_database.dart';
import '../../providers/database_provider.dart';
import '../../providers/task_detail_provider.dart';
import '../../services/clarification_service.dart';
import '../../widgets/clarify_shared_widgets.dart';
import '../../widgets/process_to_handlers.dart';

class InboxClarifyScreen extends ConsumerStatefulWidget {
  const InboxClarifyScreen({super.key, required this.captureId});

  final String captureId;

  @override
  ConsumerState<InboxClarifyScreen> createState() => _InboxClarifyScreenState();
}

class _InboxClarifyScreenState extends ConsumerState<InboxClarifyScreen> {
  late TextEditingController _titleCtrl;
  late TextEditingController _notesCtrl;
  String? _energyLevel;
  int? _timeEstimate;
  DateTime? _dueDate;
  Capture? _capture;

  /// True once local storage has answered with no row for [widget.captureId].
  ///
  /// Distinct from "not answered yet": the screen renders a spinner while the
  /// subject is unknown and a missing-item state once it is known to be gone.
  bool _subjectMissing = false;

  /// The subject values last written into the controllers — either seeded from
  /// the row or saved back to it.
  ///
  /// A controller whose text still matches its marker is *clean*: the user has
  /// not typed since, so an incoming change may be applied to it. Anything
  /// else is a local edit in progress and is left alone. Null until the first
  /// row arrives, which is what makes the first emission seed the fields.
  String? _appliedTitle;
  String? _appliedNotes;

  /// Mirrors `_titleCtrl.text.trim().isEmpty` so the routing buttons and the
  /// title's error state react as the user types. An Outcome must be
  /// nameable, so a blank title disables every route that creates one.
  bool _titleIsBlank = false;

  /// Mirrors [ProcessToHandlers]' in-flight state, so every affordance that
  /// leaves this screen — Skip, the app-bar back button, platform back —
  /// shuts alongside the bar's own buttons.
  ///
  /// Popping mid-write is not merely cosmetic: the routing verdict lands, but
  /// the widget unmounts before `onAfterRoute` runs, so [_saveCaptureText] is
  /// skipped and the Capture keeps a title the Outcome no longer has.
  bool _routing = false;

  /// Non-person tag hints on this Capture, read once alongside it.
  ///
  /// They seed the new Outcome's tags via the draft. A one-shot read (not a
  /// watch) because this screen renders no tag pickers — there is nothing on
  /// screen for a live stream to keep in step, and subscribing to a live drift
  /// query from a widget leaves a pending timer that hangs `pumpAndSettle`
  /// (docs/TESTING.md).
  Set<String> _hintTagIds = const <String>{};

  static const _estimateOptions = [5, 10, 15, 30, 45, 60, 90, 120];

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController();
    _notesCtrl = TextEditingController();
    _loadTagHints();
  }

  /// Reads the tag hints that seed the new Outcome's tags.
  ///
  /// Failing to read them costs the user their hints, not their clarification,
  /// so it leaves the screen usable with an empty set rather than tearing it
  /// down — the subject the screen actually renders comes from elsewhere.
  Future<void> _loadTagHints() async {
    final List<Tag> hints;
    try {
      hints = await ref
          .read(databaseProvider)
          .captureDao
          .tagHintsForCapture(widget.captureId);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    setState(() {
      // Person hints are excluded: delegation is the orthogonal axis and the
      // Waiting For picker is the only thing that writes it.
      _hintTagIds = {
        for (final t in hints)
          if (t.type != 'person') t.id,
      };
    });
  }

  /// Reconciles the screen with the subject as local storage now holds it.
  ///
  /// Applied to clean fields only — see [_appliedTitle]. Energy, estimate and
  /// due date have no column on a Capture, so there is nothing to reconcile
  /// for them; they stay draft state until the Outcome is minted.
  void _applySubject(Capture? capture) {
    if (!mounted) return;
    if (capture == null) {
      setState(() {
        _capture = null;
        _subjectMissing = true;
      });
      return;
    }
    setState(() {
      _capture = capture;
      _subjectMissing = false;
      if (_appliedTitle == null || _titleCtrl.text.trim() == _appliedTitle) {
        if (_titleCtrl.text != capture.title) _titleCtrl.text = capture.title;
        _appliedTitle = capture.title.trim();
        _titleIsBlank = _appliedTitle!.isEmpty;
      }
      final notes = capture.notes ?? '';
      if (_appliedNotes == null || _notesCtrl.text.trim() == _appliedNotes) {
        if (_notesCtrl.text != notes) _notesCtrl.text = notes;
        _appliedNotes = notes.trim();
      }
    });
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  /// Snapshot of the card's state, read at tap time by [CaptureSubject.draft]
  /// and applied by [ClarificationService.clarifyCaptureToOutcome] to the
  /// Outcome it mints. Reading it at tap time (rather than at build time) is
  /// what lets the live controller text win over the last-saved Capture row.
  ClarifyDraft _draft() {
    final title = _titleCtrl.text.trim();
    final notes = _notesCtrl.text.trim();
    return ClarifyDraft(
      title: title,
      notes: notes.isEmpty ? null : notes,
      energyLevel: _energyLevel,
      timeEstimate: _timeEstimate,
      // Strip the time component: the picker collects a calendar day.
      dueDate: _dueDate != null
          ? DateTime(_dueDate!.year, _dueDate!.month, _dueDate!.day)
          : null,
      tagIds: _hintTagIds,
      // Title-as-action: a Capture is always a first clarification, so there
      // is no deliberate phrase to clobber. Consumed only for Next and
      // Waiting For.
      nextActionText: title.isEmpty ? null : title,
    );
  }

  /// Persists the Capture's text edits, keeping the provenance record in step
  /// with what the user actually wrote.
  ///
  /// Skipped entirely for a blank title. The only route that survives a blank
  /// title is Discard (every other button is disabled), and writing `title:
  /// ''` onto a Capture whose `clarified_at` was just stamped would destroy
  /// the record of *what* was discarded — the original fragment is the
  /// correct history. Notes are skipped with it: a blank-titled discard has no
  /// edit worth keeping.
  ///
  /// `clearNotes` is driven by the field alone: clearing an already-null
  /// column is a no-op, so there is no need to know what the row held — and
  /// no load-time snapshot to get it wrong.
  Future<void> _saveCaptureText() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) return;
    if (_capture == null) return;
    final notes = _notesCtrl.text.trim();
    await ref.read(databaseProvider).captureDao.updateFields(
          widget.captureId,
          title: title,
          notes: notes.isNotEmpty ? notes : null,
          clearNotes: notes.isEmpty,
        );
    // What we just wrote is now what the row holds, so the fields are clean
    // again and a later incoming change may be applied to them.
    if (!mounted) return;
    _appliedTitle = title;
    _appliedNotes = notes;
  }

  Future<DateTime?> _pickDate() {
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
    // Reconcile from the listener rather than from the build itself: applying
    // a change writes into the controllers, and a controller that notifies
    // its TextField mid-build would rebuild a widget that is already building.
    ref.listen<AsyncValue<Capture?>>(
      captureProvider(widget.captureId),
      (_, next) => next.whenData(_applySubject),
    );
    return PopScope(
      // Platform back is the one escape no widget owns, so it needs the guard
      // here rather than an `enabled:` flag. Shut while a route is in flight,
      // for the reason [_routing] documents.
      canPop: !_routing,
      child: _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('Clarify'),
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          onPressed: _routing ? null : () => context.pop(),
        ),
      ),
      body: _subjectMissing
          ? const ClarifySubjectMissing()
          : _capture == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
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

                // Title
                TextField(
                  key: const Key('clarify_title'),
                  controller: _titleCtrl,
                  onChanged: (value) {
                    final blank = value.trim().isEmpty;
                    if (blank != _titleIsBlank) {
                      setState(() => _titleIsBlank = blank);
                    }
                  },
                  decoration: InputDecoration(
                    labelText: 'Title',
                    errorText:
                        _titleIsBlank ? 'Title is required to process' : null,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                  textCapitalization: TextCapitalization.sentences,
                  maxLines: 2,
                  minLines: 1,
                ),
                const SizedBox(height: 12),

                // Notes
                TextField(
                  key: const Key('clarify_notes'),
                  controller: _notesCtrl,
                  decoration: InputDecoration(
                    labelText: 'Notes (optional)',
                    hintText: 'Context, desired outcome, dependencies…',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                  textCapitalization: TextCapitalization.sentences,
                  maxLines: 4,
                  minLines: 2,
                ),
                const SizedBox(height: 20),

                // Energy level
                const ClarifyFieldLabel('ENERGY LEVEL'),
                const SizedBox(height: 8),
                ClarifyEnergyPicker(
                  selected: _energyLevel,
                  onSelect: (level) => setState(() => _energyLevel = level),
                ),
                const SizedBox(height: 20),

                // Time estimate
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
                      onTap: () =>
                          setState(() => _timeEstimate = selected ? null : m),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 20),

                // Due date
                const ClarifyFieldLabel('DUE DATE'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: () async {
                        final picked = await _pickDate();
                        if (picked != null && mounted) {
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

                // Destinations. The canonical action bar owns every routing
                // write — including the zero-Outcome Discard — so this screen
                // cannot drift from the ceremony clarify surfaces.
                const ClarifyFieldLabel('PROCESS TO'),
                const SizedBox(height: 12),
                ProcessToHandlers(
                  subject: CaptureSubject(
                    capture: _capture!,
                    draft: _draft,
                  ),
                  // Title is required to name an Outcome, so the four routes
                  // that create one are gated on it. Discard stays enabled:
                  // an unnamed fragment is exactly the kind of thing a user
                  // wants to throw away.
                  disabled: _titleIsBlank
                      ? const <ProcessAction>{
                          ProcessAction.next,
                          ProcessAction.waitingFor,
                          ProcessAction.someday,
                          ProcessAction.done,
                        }
                      : const <ProcessAction>{},
                  // Opt out of the default-on `nextActionDialog` modifier:
                  // this screen supplies the phrase via the title-as-action
                  // coupling in [_draft], so Next routes immediately.
                  except: const {ProcessAction.nextActionDialog},
                  // Skip lives outside the bar, so it does not get the bar's
                  // own in-flight disabling for free — mirror the state out.
                  onProcessingChanged: (busy) {
                    if (mounted) setState(() => _routing = busy);
                  },
                  onAfterRoute: (_) async {
                    if (!mounted) return;
                    // The routing verdict is already committed. Persisting the
                    // text is best-effort bookkeeping on top of it, so a
                    // failure must not strand the user on a screen whose
                    // buttons would re-route an item that is already clarified
                    // — leave regardless, and let ProcessToHandlers report it.
                    try {
                      await _saveCaptureText();
                    } finally {
                      // `this.context` (not the build parameter) so the guard
                      // is the matching State.mounted check.
                      if (mounted) this.context.pop();
                    }
                  },
                ),
                const SizedBox(height: 20),
                // Skip is a nav escape hatch, not a verdict — it leaves
                // `clarified_at` NULL and the Capture in the Inbox — so it
                // stays outside the routing bar, and so it does not inherit
                // the bar's in-flight disabling for free (see [_routing]).
                ClarifyDestinationButton(
                  label: 'Skip',
                  icon: Icons.next_plan_outlined,
                  color: const Color(0xFF6B7280),
                  enabled: !_routing,
                  onTap: () => context.pop(),
                ),
              ],
            ),
    );
  }
}
