/// Standalone clarify screen for a single Inbox Capture.
///
/// Opened when the user taps an inbox row outside of a planning session. It
/// watches its own Capture and pops once the item is clarified, but the routing
/// verdict itself is not its own: the action bar is [ProcessToHandlers], the
/// same widget every ceremony clarify surface renders, so the destinations,
/// their copy and the writes behind them cannot drift from those surfaces.
///
/// The Capture is watched live and rendered through [AsyncSubject], so
/// loading, an error and a Capture hard-deleted on another device are three
/// distinguishable states rather than one indefinite spinner.
///
/// Title and notes are saved onto the Capture after a successful route.
/// Energy, time estimate and due date have no column on a Capture (ADR-0006) —
/// they are held as draft state here and ride the [ClarifyDraft] into the
/// Outcome that [ClarificationService.clarifyCaptureToOutcome] creates.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../database/gtd_database.dart';
import '../../providers/database_provider.dart';
import '../../providers/task_detail_provider.dart';
import '../../services/clarification_service.dart';
import '../../widgets/async_subject.dart';
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

  /// The most recent *present* emission of [captureProvider].
  ///
  /// A live mirror, not a load-time snapshot: `dataBuilder` reassigns it on
  /// every emission, so [_saveCaptureText]'s `hadNotes` reads the Capture as
  /// it stands now rather than as it looked when the screen opened. Held as a
  /// field only because the routing callbacks that need it fire outside
  /// `build`.
  Capture? _capture;

  /// Whether the text controllers have been seeded from a loaded Capture.
  /// Seeding stays one-shot even though the screen now sees every
  /// re-emission: adopting a synced edit mid-typing would clobber the user's
  /// in-progress text. The per-field merge that makes adoption safe is #427's.
  bool _seeded = false;

  /// Whether the missing-state escape has already been taken — see the CTA in
  /// [_buildScaffold]. Navigator already absorbs a second `pop` against a
  /// route mid-transition, so the latch guards the invariant rather than an
  /// observed bug; it stops mattering only for as long as this CTA does
  /// nothing but pop.
  bool _missingEscapeFired = false;

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

  /// Whether [_loadHints] has finished — resolved *or* failed. Gates the four
  /// Outcome-creating routes; see [_loadHints] for why.
  bool _hintsSettled = false;

  static const _estimateOptions = [5, 10, 15, 30, 45, 60, 90, 120];

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController();
    _notesCtrl = TextEditingController();
    _loadHints();
  }

  /// Reads the Capture's tag hints once. The Capture itself is watched (see
  /// [_buildScaffold]); only the hints stay a one-shot read, for the reason
  /// [_hintTagIds] documents.
  ///
  /// A failure here is not fatal: the hints only seed the new Outcome's tags,
  /// so the screen stays usable and the user loses tag seeding rather than the
  /// ability to clarify. A missing Capture is no longer this method's problem
  /// — the watch renders it as the missing state.
  ///
  /// Either way this settles [_hintsSettled], which ungates the routing
  /// buttons. Until it does, the four Outcome-creating routes are disabled:
  /// the hints ride the draft into `clarifyCaptureToOutcome`, so a tap landing
  /// first would mint an Outcome missing every tag the Capture carried, with
  /// nothing on screen to suggest anything was lost. This screen used to load
  /// the hints alongside the Capture behind one spinner; binding the Capture
  /// to a watch left them racing.
  Future<void> _loadHints() async {
    try {
      final hints = await ref
          .read(databaseProvider)
          .captureDao
          .tagHintsForCapture(widget.captureId);
      if (!mounted) return;
      setState(() {
        // Person hints are excluded: delegation is the orthogonal axis and the
        // Waiting For picker is the only thing that writes it.
        _hintTagIds = {
          for (final t in hints)
            if (t.type != 'person') t.id,
        };
        _hintsSettled = true;
      });
    } catch (e) {
      if (!mounted) return;
      // Settle on failure too. The hints are a seeding nicety, not a
      // precondition for clarifying, so a failed read must degrade to "route
      // without them" rather than leaving the destinations disabled forever.
      setState(() => _hintsSettled = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't load this item's tags.")),
      );
    }
  }

  /// Seeds the editors from the first present emission. Energy / estimate /
  /// due start empty: a Capture carries none of them.
  void _seedFrom(Capture capture) {
    if (_seeded) return;
    _seeded = true;
    _titleCtrl.text = capture.title;
    _notesCtrl.text = capture.notes ?? '';
    _titleIsBlank = capture.title.trim().isEmpty;
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
  Future<void> _saveCaptureText() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) return;
    final capture = _capture;
    if (capture == null) return;
    final notes = _notesCtrl.text.trim();
    final hadNotes = (capture.notes ?? '').isNotEmpty;
    await ref
        .read(databaseProvider)
        .captureDao
        .updateFields(
          widget.captureId,
          title: title,
          notes: notes.isNotEmpty ? notes : null,
          clearNotes: notes.isEmpty && hadNotes,
        );
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
    return PopScope(
      // Platform back is the one escape no widget owns, so it needs the guard
      // here rather than an `enabled:` flag. Shut while a route is in flight,
      // for the reason [_routing] documents.
      canPop: !_routing,
      child: _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    final captureAsync = ref.watch(captureProvider(widget.captureId));
    // Latch the deletion. `dataBuilder` is not called on the missing branch, so
    // [_capture] would otherwise keep the last row it saw and
    // [_saveCaptureText]'s null guard would sail straight past it, writing
    // `updateFields` to a row that is gone — a harmless no-op under
    // `NativeDatabase`, but in production PowerSync queues the UPDATE, the
    // backend 404s it, and it lands in `sync_dead_letters`. `hasValue` with a
    // null value is the same "gone, not loading" test [AsyncSubject] makes;
    // mirrors `ClarifyCard`'s `_subjectGone`.
    if (captureAsync.hasValue && captureAsync.value == null) _capture = null;
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
      body: AsyncSubject<Capture>(
        asyncValue: captureAsync,
        missingIcon: Icons.inbox_outlined,
        missingTitle: 'This item is no longer in your Inbox',
        missingSubtitle: 'It may have been deleted on another device.',
        missingCta: FilledButton(
          onPressed: () {
            if (_missingEscapeFired) return;
            _missingEscapeFired = true;
            context.pop();
          },
          child: const Text('Back to Inbox'),
        ),
        dataBuilder: (context, capture) {
          _capture = capture;
          _seedFrom(capture);
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
                child: const Row(
                  children: [
                    Icon(
                      Icons.help_outline,
                      size: 18,
                      color: Color(0xFF2563EB),
                    ),
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
                  errorText: _titleIsBlank
                      ? 'Title is required to process'
                      : null,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
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
                    borderRadius: BorderRadius.circular(8),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
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
                subject: CaptureSubject(capture: capture, draft: _draft),
                // The same four routes are gated twice, for two reasons that
                // both come down to what an Outcome must carry. A title,
                // because an Outcome must be nameable; and settled tag hints,
                // because they ride the draft into the Outcome and a tap that
                // beats the hint read would silently drop them. Discard is
                // exempt from both: it creates no Outcome, so it needs neither
                // a name nor tags — an unnamed fragment is exactly the kind of
                // thing a user wants to throw away.
                disabled: (_titleIsBlank || !_hintsSettled)
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
          );
        },
      ),
    );
  }
}
