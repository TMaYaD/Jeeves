/// The n-m clarify surface: the Outcomes a Capture has yielded, the inline
/// form that adds another, and the verdict that ends the clarify act
/// (issue #434).
///
/// Rendered instead of the 1-1 body when `clarifyMode == ClarifyMode.nToM`.
/// The two modes are a preference over the *same* many-to-many storage, never
/// a storage change (CONTEXT.md § GTD Core, ADR-0006).
///
/// Top to bottom: the Capture's own text, read-only — in this mode the Capture
/// is the record of what was thought, not the thing being shaped, so it is not
/// an editable field here; then the Outcomes carved from or linked to it; then
/// the call to add another, which swaps in place for the New Outcome form; and
/// last the verdict.
///
/// **One field, two verbs.** The form's Outcome field is the whole merge
/// affordance: typing matches live Outcomes by title, and picking one *links*
/// this Capture to work that already exists — merge links, it never consumes.
/// A trailing `Create "…"` row keeps what was typed and carves a new Outcome
/// instead. There are deliberately no separate "new" and "link existing"
/// controls: splitting one Capture into several Outcomes and merging several
/// Captures into one are the same gesture, so they get the same control.
///
/// **Routing narrows to three destinations.** Next Action / Waiting For /
/// Someday, with Done and Trash parameterised out of the shared
/// [ProcessToHandlers] rather than forked away from it. An Outcome captured
/// already-complete is a contradiction — Done is a completion event, not a
/// destination you route to while clarifying — and trashing an Outcome belongs
/// on the Outcome's own surface. Both remain available there.
///
/// **The verdict takes the slot Done and Trash vacate**, in that same bar, so
/// its inset, height, gap and radius are the routing buttons' own rather than
/// a hand-matched copy of them. It reads "Discard Capture" (red, `trash`) when
/// the Outcomes list is empty and "Done with this Capture" (green,
/// `completeCapture`) otherwise. A half-written form does not count: an
/// Outcome that was never routed is not one this Capture yielded.
///
/// **1-1 is this surface with two parameters flipped** — its Outcomes list is
/// always empty, so the list and the call-to-add render nothing at all and the
/// form is already open; and its routing completes the Capture outright
/// instead of collapsing into a row (see
/// [CaptureSubject.completesClarification]).
///
/// The surface binds to the Capture's links live, so it reflects the local
/// Drift rows and nothing else — it cannot tell whether a change arrived from
/// another screen, a background job or a replicated write, and does not try
/// (ARCHITECTURE.md § Sync Engine).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/capture_dao.dart' show CarvedOutcome;
import '../database/gtd_database.dart';
import '../models/action_draft.dart';
import '../providers/auth_provider.dart';
import '../providers/database_provider.dart';
import '../providers/task_detail_provider.dart';
import '../services/clarification_service.dart';
import 'async_list.dart';
import 'clarify_shared_widgets.dart';
import 'process_to_handlers.dart';

const _labelGray = Color(0xFF9CA3AF);
const _textGray = Color(0xFF6B7280);
const _borderGray = Color(0xFFD1D5DB);
const _accentBlue = Color(0xFF2563EB);
const _surfaceGray = Color(0xFFF9FAFB);
const _errorRed = Color(0xFFDC2626);

/// Radii from the canonical scale (docs/DESIGN.md § Roundedness): 2 buttons,
/// 4 chips and inputs, 6 surfaces.
const _radiusChip = BorderRadius.all(Radius.circular(4));
const _radiusSurface = BorderRadius.all(Radius.circular(6));

/// Shown when one of this surface's own writes (merge, retract) throws.
///
/// Routing and verdict failures are deliberately not reported here:
/// [ProcessToHandlers] owns those taps and reports them itself, so repeating
/// the message would show two banners for one failure.
const _kWriteFailedMessage = 'Operation failed. Please try again.';

/// Time-estimate options, matching the 1-1 clarify surfaces.

class CaptureOutcomesSection extends ConsumerStatefulWidget {
  const CaptureOutcomesSection({
    super.key,
    required this.capture,
    this.tagIds = const {},
    this.onCompleted,
  });

  /// The Capture being clarified. Rendered read-only at the top, and the
  /// subject of every write this surface performs.
  final Capture capture;

  /// Tag hints on the Capture, seeding each new Outcome's tags so a carve
  /// starts where a 1-1 clarification would.
  final Set<String> tagIds;

  /// Called after the verdict lands — the host owns the exit (pop the screen,
  /// advance the ceremony cursor).
  final Future<void> Function()? onCompleted;

  @override
  ConsumerState<CaptureOutcomesSection> createState() =>
      _CaptureOutcomesSectionState();
}

class _CaptureOutcomesSectionState
    extends ConsumerState<CaptureOutcomesSection> {
  final _titleCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  String? _energyLevel;
  int? _timeEstimate;
  DateTime? _dueDate;

  /// Outcomes carved during *this* clarify session. Retracting one of these
  /// deletes it; retracting anything else only detaches.
  ///
  /// Session-scoped by design: it is the record of what this surface created,
  /// which no column on either row can answer — a merged Outcome and a carved
  /// one are the same `todos` row once written.
  final _carvedThisSession = <String>{};

  /// Whether the New Outcome form is showing. Opened by the call-to-add, and
  /// open from the start while the list is empty so the first Outcome never
  /// costs an extra tap. Null until the first list emission decides it.
  bool? _formOpen;

  /// Title matches for the current query. Empty while the field is empty.
  List<Todo> _matches = const [];

  /// Monotonic token for the in-flight search, so a slow query for an earlier
  /// keystroke cannot overwrite the results of a later one.
  int _searchToken = 0;

  /// True while one of this surface's own writes is in flight.
  bool _busy = false;

  /// Set when one of those writes fails, cleared when the next one starts.
  String? _error;

  /// Mirrors `_titleCtrl.text.trim().isEmpty`: an Outcome must be nameable, so
  /// a blank title disables every destination that would create one.
  bool _titleIsBlank = true;

  /// The Outcome ids this Capture claimed as of the last build.
  Set<String> _knownOutcomeIds = const {};

  /// [_knownOutcomeIds] as it stood the instant a routing tap began, before
  /// that tap's write. Whatever the Capture claims afterwards that is not in
  /// here is what the carve created.
  Set<String> _idsBeforeCarve = const {};

  ClarificationService get _clarification =>
      ref.read(clarificationServiceProvider);

  @override
  void dispose() {
    _titleCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _onTitleChanged(String value) async {
    final query = value.trim();
    final blank = query.isEmpty;
    if (blank != _titleIsBlank) setState(() => _titleIsBlank = blank);
    final token = ++_searchToken;
    if (blank) {
      if (mounted) setState(() => _matches = const []);
      return;
    }
    final List<Todo> found;
    try {
      found = await ref
          .read(databaseProvider)
          .todoDao
          .searchOutcomesByTitle(query);
    } catch (_) {
      // A failed *search* costs the user their merge suggestions, not their
      // clarification: what they typed still names a new Outcome, and routing
      // it still works. A banner on every keystroke would be noise.
      return;
    }
    if (!mounted || token != _searchToken) return;
    setState(() => _matches = found);
  }

  /// Runs [write] with the surface shut, surfacing a failure inline.
  ///
  /// The failure has to reach the user *here*: this surface owns the tap, so
  /// nothing above it can wrap the write in its own handler, and an uncaught
  /// async error would leave the affordance looking like it simply did
  /// nothing. The `_busy` reset stays in the `finally` so a throw cannot latch
  /// the surface shut.
  Future<void> _run(Future<void> Function() write) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await write();
    } catch (_) {
      if (mounted) setState(() => _error = _kWriteFailedMessage);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Links the Capture to an Outcome that already exists, and closes the form
  /// over it — the merge is the whole act, so there is nothing left to route.
  Future<void> _merge(Todo outcome) => _run(() async {
        await _clarification.mergeIntoOutcome(
          widget.capture.id,
          outcome.id,
          userId: ref.read(currentUserIdProvider),
        );
        _resetForm(open: false);
      });

  /// Retracts this Capture's claim on [outcomeId] — deleting it when this
  /// session carved it, detaching it when it pre-existed.
  Future<void> _retract(String outcomeId) => _run(() async {
        await _clarification.unlinkOutcome(
          widget.capture.id,
          outcomeId,
          deleteCarved: _carvedThisSession.contains(outcomeId),
        );
        _carvedThisSession.remove(outcomeId);
      });

  /// Clears the form's fields, leaving it open or collapsed per [open].
  void _resetForm({required bool open}) {
    _titleCtrl.clear();
    _notesCtrl.clear();
    _searchToken++;
    if (!mounted) return;
    setState(() {
      _matches = const [];
      _energyLevel = null;
      _timeEstimate = null;
      _dueDate = null;
      _titleIsBlank = true;
      _formOpen = open;
    });
  }

  /// Snapshot of the form, read at tap time by [CaptureSubject.draft] and
  /// written onto the Outcome the routing carves. Reading it at tap time
  /// (rather than at build time) is what lets live controller text win.
  ClarifyDraft _draft() {
    // Read at tap time by [CaptureSubject.draft], synchronously ahead of the
    // write it feeds — which is what makes this a reliable "before" snapshot.
    // Diffing against a value re-read after the write would race the live
    // stream, and losing that race would silently downgrade a carve to a
    // merge, so a later retraction would detach instead of deleting.
    _idsBeforeCarve = Set.of(_knownOutcomeIds);
    final title = _titleCtrl.text.trim();
    final notes = _notesCtrl.text.trim();
    return ClarifyDraft(
      title: title,
      notes: notes.isEmpty ? null : notes,
      // Strip the time component: the picker collects a calendar day.
      dueDate: _dueDate != null
          ? DateTime(_dueDate!.year, _dueDate!.month, _dueDate!.day)
          : null,
      tagIds: widget.tagIds,
      // Title-as-action: a freshly carved Outcome must not land on the Next
      // list actionless. The effort values ride along on the same draft and
      // land on the Outcome columns whatever the destination (D3).
      action: title.isEmpty
          ? null
          : ActionDraft(
              text: title,
              energyLevel: _energyLevel,
              timeEstimateMinutes: _timeEstimate,
            ),
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

  /// Records the Outcome the routing just carved as this session's, so
  /// retracting it deletes rather than detaches, and collapses the form.
  Future<void> _onCarved() async {
    final ids = await ref
        .read(databaseProvider)
        .captureDao
        .outcomeIdsForCapture(widget.capture.id);
    _carvedThisSession.addAll(
      ids.where((id) => !_idsBeforeCarve.contains(id)),
    );
    _resetForm(open: false);
  }

  @override
  Widget build(BuildContext context) {
    final linkedAsync = ref.watch(carvedOutcomesProvider(widget.capture.id));
    // `.value`, not `asData`: a re-subscribe puts the provider back into
    // loading *with the last value still attached*, and `asData` throws that
    // away — blanking the rows and springing the form open mid-session.
    final linked = linkedAsync.value ?? const <CarvedOutcome>[];
    // Error before absence: Riverpod hands back the previous value alongside
    // an error too, so an absence-first read would call a list that failed to
    // load "empty" and let the destructive verdict act on it
    // (widgets/state_surfaces.dart). Loading with no value yet is likewise not
    // an answer — only a list that came back, and came back clean, is.
    final outcomesKnownEmpty =
        !linkedAsync.hasError && linkedAsync.hasValue && linked.isEmpty;
    final outcomesPending = !linkedAsync.hasError && !linkedAsync.hasValue;
    final linkedIds = {for (final l in linked) l.outcome.id};
    _knownOutcomeIds = linkedIds;
    // The form opens itself while there is nothing in the list, so the first
    // Outcome costs no extra tap; once a row exists the call-to-add owns it.
    final formOpen = _formOpen ?? linked.isEmpty;
    final query = _titleCtrl.text.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CaptureText(capture: widget.capture),
        const SizedBox(height: 24),
        // An empty list renders *nothing* — no header, no empty state. There
        // is nothing to say about it that the open form below does not already
        // say by being open, and it is what makes 1-1 mode look unchanged.
        if (linkedAsync.hasError || linked.isNotEmpty) ...[
          const ClarifyFieldLabel('OUTCOMES'),
          const SizedBox(height: 8),
          // Error before absence: a link list that failed to load is not the
          // same as a Capture with no Outcomes yet
          // (widgets/state_surfaces.dart).
          AsyncList<CarvedOutcome>(
            asyncValue: linkedAsync,
            emptyTitle: 'No Outcomes yet',
            emptyBuilder: (_) => const SizedBox.shrink(),
            dataBuilder: (context, items) => Column(
              children: [
                for (final item in items)
                  _LinkedOutcomeRow(
                    key: Key('linked_outcome_${item.outcome.id}'),
                    item: item,
                    enabled: !_busy,
                    onRetract: () => _retract(item.outcome.id),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (!formOpen)
          _AddOutcomeCall(
            enabled: !_busy,
            onTap: () => _resetForm(open: true),
          ),
        if (formOpen)
          _NewOutcomeForm(
            titleCtrl: _titleCtrl,
            notesCtrl: _notesCtrl,
            enabled: !_busy,
            energyLevel: _energyLevel,
            onEnergy: (level) => setState(() => _energyLevel = level),
            timeEstimate: _timeEstimate,
            onEstimate: (m) => setState(() => _timeEstimate = m),
            dueDate: _dueDate,
            onPickDate: () async {
              final picked = await _pickDate();
              if (picked != null && mounted) {
                setState(() => _dueDate = picked);
              }
            },
            onClearDate: () => setState(() => _dueDate = null),
            onTitleChanged: _onTitleChanged,
            titleIsBlank: _titleIsBlank,
            suggestions: query.isEmpty
                ? null
                : _Suggestions(
                    query: query,
                    // An Outcome this Capture already claims is not a merge
                    // candidate — offering it would be a no-op row.
                    matches: [
                      for (final m in _matches)
                        if (!linkedIds.contains(m.id)) m,
                    ],
                    enabled: !_busy,
                    onMerge: _merge,
                  ),
          ),
        const SizedBox(height: 20),
        if (_error != null)
          Padding(
            key: const Key('capture_outcomes_error'),
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _error!,
              style: const TextStyle(fontSize: 13, color: _errorRed),
            ),
          ),
        _RoutingAndVerdict(
          capture: widget.capture,
          draft: _draft,
          formOpen: formOpen,
          outcomesKnownEmpty: outcomesKnownEmpty,
          outcomesPending: outcomesPending,
          titleIsBlank: _titleIsBlank,
          onCarved: _onCarved,
          onCompleted: widget.onCompleted,
        ),
      ],
    );
  }
}

/// The Capture as it was written down, read-only.
///
/// Not a field: in n-m mode the Capture is provenance — the record of the
/// original thought — and the thing being shaped is the Outcome below it.
class _CaptureText extends StatelessWidget {
  const _CaptureText({required this.capture});

  final Capture capture;

  @override
  Widget build(BuildContext context) {
    final notes = capture.notes?.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ClarifyFieldLabel('CAPTURE'),
        const SizedBox(height: 8),
        Container(
          key: const Key('capture_text'),
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _surfaceGray,
            borderRadius: _radiusSurface,
            border: Border.all(color: _borderGray),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                capture.title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (notes != null && notes.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  notes,
                  style: const TextStyle(fontSize: 13, color: _textGray),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                _capturedOn(capture.createdAt),
                style: const TextStyle(fontSize: 11, color: _labelGray),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _capturedOn(DateTime at) {
    final local = at.toLocal();
    final d = '${local.year}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
    return 'Captured $d';
  }
}

/// One Outcome the Capture claims: its title, its next action, its Contexts,
/// and the ✕ that retracts the claim.
class _LinkedOutcomeRow extends StatelessWidget {
  const _LinkedOutcomeRow({
    super.key,
    required this.item,
    required this.enabled,
    required this.onRetract,
  });

  final CarvedOutcome item;
  final bool enabled;
  final VoidCallback onRetract;

  @override
  Widget build(BuildContext context) {
    final action = item.currentActionText?.trim();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: _surfaceGray,
        borderRadius: _radiusSurface,
        border: Border.all(color: _borderGray),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.outcome.title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (action != null && action.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    action,
                    style: const TextStyle(fontSize: 12, color: _textGray),
                  ),
                ],
                if (item.contexts.isNotEmpty || item.isMerged) ...[
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final name in item.contexts) _Chip(label: name),
                      if (item.isMerged)
                        _Chip(label: 'from ${item.captureCount} Captures'),
                    ],
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            color: _labelGray,
            // The ✕ retracts *this Capture's* claim. What that costs depends
            // on provenance — a merged Outcome is let go of, a session-carved
            // one ceases to exist — which the label cannot say in two words,
            // so it names the act rather than the consequence.
            tooltip: 'Remove from this Capture',
            onPressed: enabled ? onRetract : null,
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: _accentBlue.withValues(alpha: 0.08),
        borderRadius: _radiusChip,
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: _accentBlue,
        ),
      ),
    );
  }
}

/// The call to add another Outcome, which the form replaces in place.
class _AddOutcomeCall extends StatelessWidget {
  const _AddOutcomeCall({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const Key('add_outcome_call'),
      onTap: enabled ? onTap : null,
      borderRadius: _radiusSurface,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: _radiusSurface,
          border: Border.all(color: _borderGray),
        ),
        child: const Row(
          children: [
            Icon(Icons.add, size: 18, color: _accentBlue),
            SizedBox(width: 8),
            Text(
              'Add another Outcome',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: _accentBlue,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The inline New Outcome form — the same attributes the 1-1 card collects,
/// carried onto the Outcome the routing below carves.
class _NewOutcomeForm extends StatelessWidget {
  const _NewOutcomeForm({
    required this.titleCtrl,
    required this.notesCtrl,
    required this.enabled,
    required this.energyLevel,
    required this.onEnergy,
    required this.timeEstimate,
    required this.onEstimate,
    required this.dueDate,
    required this.onPickDate,
    required this.onClearDate,
    required this.onTitleChanged,
    required this.titleIsBlank,
    required this.suggestions,
  });

  final TextEditingController titleCtrl;
  final TextEditingController notesCtrl;
  final bool enabled;
  final String? energyLevel;
  final ValueChanged<String?> onEnergy;
  final int? timeEstimate;
  final ValueChanged<int?> onEstimate;
  final DateTime? dueDate;
  final VoidCallback onPickDate;
  final VoidCallback onClearDate;
  final ValueChanged<String> onTitleChanged;
  final bool titleIsBlank;
  final Widget? suggestions;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ClarifyFieldLabel('NEW OUTCOME'),
        const SizedBox(height: 8),
        // One field, two verbs: what is typed here either names a new Outcome
        // or finds an existing one to merge into.
        TextField(
          key: const Key('outcome_title'),
          controller: titleCtrl,
          enabled: enabled,
          onChanged: onTitleChanged,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Outcome',
            hintText: 'Name it, or type to find an existing one…',
            border: OutlineInputBorder(borderRadius: _radiusChip),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          maxLines: 2,
          minLines: 1,
        ),
        if (suggestions != null) ...[
          const SizedBox(height: 8),
          suggestions!,
        ],
        const SizedBox(height: 12),
        TextField(
          key: const Key('outcome_notes'),
          controller: notesCtrl,
          enabled: enabled,
          decoration: const InputDecoration(
            labelText: 'Notes (optional)',
            border: OutlineInputBorder(borderRadius: _radiusChip),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          textCapitalization: TextCapitalization.sentences,
          maxLines: 4,
          minLines: 2,
        ),
        const SizedBox(height: 20),
        const ClarifyFieldLabel('ENERGY LEVEL'),
        const SizedBox(height: 8),
        ClarifyEnergyPicker(selected: energyLevel, onSelect: onEnergy),
        const SizedBox(height: 20),
        const ClarifyFieldLabel('TIME ESTIMATE'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: kEstimateOptionsMinutes.map((m) {
            final selected = timeEstimate == m;
            return ClarifyEstimateChip(
              label: m < 60
                  ? '${m}m'
                  : m % 60 == 0
                      ? '${m ~/ 60}h'
                      : '${m ~/ 60}h ${m % 60}m',
              selected: selected,
              onTap: () => onEstimate(selected ? null : m),
            );
          }).toList(),
        ),
        const SizedBox(height: 20),
        const ClarifyFieldLabel('DUE DATE'),
        const SizedBox(height: 8),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: enabled ? onPickDate : null,
              icon: const Icon(Icons.calendar_today_outlined, size: 16),
              label: Text(
                dueDate != null
                    ? '${dueDate!.year}-'
                        '${dueDate!.month.toString().padLeft(2, '0')}-'
                        '${dueDate!.day.toString().padLeft(2, '0')}'
                    : 'Set date',
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: dueDate != null ? _accentBlue : _textGray,
              ),
            ),
            if (dueDate != null) ...[
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                color: _labelGray,
                tooltip: 'Clear date',
                onPressed: enabled ? onClearDate : null,
              ),
            ],
          ],
        ),
        if (titleIsBlank) ...[
          const SizedBox(height: 8),
          const Text(
            'Name the Outcome to route it.',
            style: TextStyle(fontSize: 12, color: _textGray),
          ),
        ],
      ],
    );
  }
}

/// Existing Outcomes whose title matches what has been typed. Picking one
/// merges; the trailing row is the reminder that what was typed will carve a
/// new Outcome when it is routed.
class _Suggestions extends StatelessWidget {
  const _Suggestions({
    required this.query,
    required this.matches,
    required this.enabled,
    required this.onMerge,
  });

  final String query;
  final List<Todo> matches;
  final bool enabled;
  final void Function(Todo) onMerge;

  @override
  Widget build(BuildContext context) {
    if (matches.isEmpty) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        borderRadius: _radiusSurface,
        border: Border.all(color: _borderGray),
      ),
      child: Column(
        children: [
          for (final match in matches)
            ListTile(
              key: Key('outcome_match_${match.id}'),
              dense: true,
              leading: const Icon(Icons.link, size: 18, color: _textGray),
              title: Text(match.title, style: const TextStyle(fontSize: 14)),
              enabled: enabled,
              onTap: enabled ? () => onMerge(match) : null,
            ),
          // Last, and present whenever anything is typed: the field must never
          // dead-end on "none of these is what I meant". Not tappable — the
          // routing buttons below already carve what is typed, and a second
          // control that did the same thing without a destination would be the
          // separate "＋ New Outcome" affordance this design removed.
          ListTile(
            key: const Key('outcome_create'),
            dense: true,
            leading: const Icon(Icons.add, size: 18, color: _accentBlue),
            title: Text(
              'Create "$query"',
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: _accentBlue,
              ),
            ),
            subtitle: const Text(
              'Route below to create it',
              style: TextStyle(fontSize: 11, color: _textGray),
            ),
          ),
        ],
      ),
    );
  }
}

/// The three destinations and the verdict, in one bar.
///
/// Deliberately a single [ProcessToHandlers]: the verdict has to sit in the
/// slot Done and Trash vacate with the routing buttons' own inset, height, gap
/// and radius, and the only way to guarantee that is to let the same parent
/// lay all of them out.
class _RoutingAndVerdict extends StatelessWidget {
  const _RoutingAndVerdict({
    required this.capture,
    required this.draft,
    required this.formOpen,
    required this.outcomesKnownEmpty,
    required this.outcomesPending,
    required this.titleIsBlank,
    required this.onCarved,
    required this.onCompleted,
  });

  final Capture capture;
  final ClarifyDraft Function() draft;
  final bool formOpen;

  /// The link list has been *read*, and it is empty. Only a read list may put
  /// the destructive verdict on the bar — loading and error are not "no
  /// Outcomes", they are "no answer".
  final bool outcomesKnownEmpty;

  /// The link list is still in flight. The verdict keeps its slot so the bar
  /// does not jump when the answer lands, but nothing may be committed on it.
  final bool outcomesPending;

  final bool titleIsBlank;
  final Future<void> Function() onCarved;
  final Future<void> Function()? onCompleted;

  @override
  Widget build(BuildContext context) {
    return ProcessToHandlers(
      subject: CaptureSubject(
        capture: capture,
        draft: draft,
        // The parameter that makes this the n-m surface: routing carves one
        // Outcome and leaves the Capture in the Inbox for the next one.
        completesClarification: false,
      ),
      include: {
        // Exactly one verdict, chosen on the *list* alone. A form filled in
        // but never routed is not an Outcome this Capture yielded, so it does
        // not turn Discard into Done. The non-destructive verdict is the
        // default: it takes the slot unless the list is known to be empty.
        if (!outcomesKnownEmpty) ProcessAction.completeCapture,
      },
      except: {
        // Done and Trash are not clarify-time destinations for an Outcome: an
        // Outcome captured already-complete is a contradiction, and trashing
        // one belongs on its own surface. Trash survives only as the
        // Capture-level Discard verdict, which is why it is withheld exactly
        // when the completing verdict is showing. Discard destroys this
        // session's carves, so it is offered only against a list that was
        // actually read and came back empty — never on a failed or pending
        // read, which would offer to discard Outcomes it simply could not see.
        ProcessAction.done,
        if (!outcomesKnownEmpty) ProcessAction.trash,
        // With no form open there is nothing to route — only a verdict to
        // give.
        if (!formOpen) ...{
          ProcessAction.next,
          ProcessAction.waitingFor,
          ProcessAction.someday,
        },
        // The Outcome field carries the phrase already (see the draft), so
        // Next routes immediately rather than opening the dialog.
        ProcessAction.nextActionDialog,
      },
      disabled: {
        if (titleIsBlank) ...{
          ProcessAction.next,
          ProcessAction.waitingFor,
          ProcessAction.someday,
        },
        // The answer is imminent, so the verdict waits for it rather than
        // committing on a list still in flight. An *errored* read gets no such
        // treatment: nothing further is coming, and leaving the user with no
        // way to finish would make the surface a dead end. Completing is safe
        // either way — it stamps the Capture and destroys nothing.
        if (outcomesPending) ProcessAction.completeCapture,
      },
      onAfterRoute: (action) async {
        switch (action) {
          case ProcessAction.completeCapture:
          case ProcessAction.trash:
            await onCompleted?.call();
          default:
            // A destination was applied to a newly carved Outcome: collapse
            // the form into the row the list is about to show, and let the
            // call-to-add offer the next one.
            await onCarved();
        }
      },
    );
  }
}
