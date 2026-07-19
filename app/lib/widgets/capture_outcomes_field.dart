/// The n-m clarify surface: one field that both links a Capture to an existing
/// Outcome and carves a new one out of it, plus the verdict footer that ends
/// the clarify act (issue #434).
///
/// Rendered only when `clarifyMode == ClarifyMode.nToM`. In 1-1 mode the
/// clarify surfaces keep their `PROCESS TO` bar untouched — the two modes are a
/// preference over the *same* many-to-many storage, never a storage change
/// (CONTEXT.md § GTD Core, ADR-0006).
///
/// **One field, two gestures.** Typing matches live Outcomes by title. Picking
/// a match *merges* — it links the Capture to work that already exists, and
/// merge links, never consumes. Picking the `Create "…"` row *splits* — it
/// carves a new Outcome and links that. There are deliberately no separate
/// "new" and "link existing" affordances: splitting one Capture into several
/// Outcomes and merging several Captures into one are the same gesture, so
/// they get the same control.
///
/// **The footer is one button whose label swaps on the linked count.** At one
/// or more Outcomes it reads "Done with this Capture"; at zero it reads
/// "Discard Capture", because a zero-Outcome clarification is a legitimate
/// verdict and not a special case (CONTEXT.md § Discard). Both stamp
/// `clarified_at` and neither asks for confirmation.
///
/// **Unlink cuts differently depending on provenance.** Unlinking an Outcome
/// this session carved deletes it — the carve is being undone, so nothing
/// should be left behind. Unlinking one that pre-existed the session merely
/// detaches it: that Outcome is the user's existing work and the merge was
/// only ever a link.
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
import '../providers/auth_provider.dart';
import '../providers/database_provider.dart';
import '../providers/task_detail_provider.dart';
import '../services/clarification_service.dart';
import 'async_list.dart';
import 'clarify_shared_widgets.dart';

const _labelGray = Color(0xFF9CA3AF);
const _textGray = Color(0xFF6B7280);
const _borderGray = Color(0xFFD1D5DB);
const _accentBlue = Color(0xFF2563EB);
const _surfaceGray = Color(0xFFF9FAFB);
const _discardGray = Color(0xFF6B7280);

/// Radii from the canonical scale (docs/DESIGN.md § Roundedness): 2 buttons,
/// 4 chips and inputs, 6 surfaces.
const _radiusButton = BorderRadius.all(Radius.circular(2));
const _radiusChip = BorderRadius.all(Radius.circular(4));
const _radiusSurface = BorderRadius.all(Radius.circular(6));

class CaptureOutcomesField extends ConsumerStatefulWidget {
  const CaptureOutcomesField({
    super.key,
    required this.captureId,
    this.tagIds = const {},
    this.onCompleted,
  });

  /// The Capture being clarified.
  final String captureId;

  /// Tag hints to attach to Outcomes carved here, so a carve seeds the same
  /// tags a 1-1 clarification would. Merge deliberately ignores them: the
  /// existing Outcome's own organisation is not this Capture's to overwrite.
  final Set<String> tagIds;

  /// Called after the verdict lands — the host owns the exit (pop the screen,
  /// advance the ceremony cursor).
  final Future<void> Function()? onCompleted;

  @override
  ConsumerState<CaptureOutcomesField> createState() =>
      _CaptureOutcomesFieldState();
}

class _CaptureOutcomesFieldState extends ConsumerState<CaptureOutcomesField> {
  final _controller = TextEditingController();

  /// Outcomes carved during *this* clarify session. Unlinking one of these
  /// deletes it; unlinking anything else only detaches (see the library doc).
  ///
  /// Session-scoped by design: it is the record of what this surface created,
  /// which no column on either row can answer — a merged Outcome and a carved
  /// one are the same `todos` row once written.
  final _carvedThisSession = <String>{};

  /// Title matches for the current query. Empty while the field is empty.
  List<Todo> _matches = const [];

  /// Monotonic token for the in-flight search, so a slow query for an earlier
  /// keystroke cannot overwrite the results of a later one.
  int _searchToken = 0;

  /// True while a link/unlink/verdict write is in flight. Shuts every
  /// affordance on the surface so a double-tap cannot double-write.
  bool _busy = false;

  ClarificationService get _clarification =>
      ref.read(clarificationServiceProvider);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onQueryChanged(String value) async {
    final token = ++_searchToken;
    final query = value.trim();
    if (query.isEmpty) {
      if (mounted) setState(() => _matches = const []);
      return;
    }
    final found =
        await ref.read(databaseProvider).todoDao.searchOutcomesByTitle(query);
    if (!mounted || token != _searchToken) return;
    setState(() => _matches = found);
  }

  /// Runs [write] with the surface shut, then clears the field. Failures leave
  /// the field's text alone so the user's typing is not thrown away along with
  /// the write.
  Future<void> _run(Future<void> Function() write) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await write();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _carve(String title) => _run(() async {
        final id = await _clarification.carveOutcome(
          widget.captureId,
          userId: ref.read(currentUserIdProvider),
          title: title,
          tagIds: widget.tagIds,
        );
        _carvedThisSession.add(id);
        _clearQuery();
      });

  Future<void> _merge(Todo outcome) => _run(() async {
        await _clarification.mergeIntoOutcome(
          widget.captureId,
          outcome.id,
          userId: ref.read(currentUserIdProvider),
        );
        _clearQuery();
      });

  Future<void> _unlink(String outcomeId) => _run(() async {
        await _clarification.unlinkOutcome(
          widget.captureId,
          outcomeId,
          deleteCarved: _carvedThisSession.contains(outcomeId),
        );
        _carvedThisSession.remove(outcomeId);
      });

  Future<void> _commitVerdict({required bool hasOutcomes}) => _run(() async {
        // Both verdicts stamp `clarified_at`; they differ only in what they
        // leave behind. Discard additionally drops anything the Capture still
        // claims, which at zero Outcomes is nothing — but routing it through
        // discardCapture keeps the zero-Outcome verdict on the one write path
        // that means it.
        if (hasOutcomes) {
          await _clarification
              .completeCaptureClarification(widget.captureId);
        } else {
          await _clarification.discardCapture(widget.captureId);
        }
        await widget.onCompleted?.call();
      });

  void _clearQuery() {
    _controller.clear();
    _searchToken++;
    _matches = const [];
  }

  @override
  Widget build(BuildContext context) {
    final linkedAsync = ref.watch(carvedOutcomesProvider(widget.captureId));
    final linked = linkedAsync.asData?.value ?? const <CarvedOutcome>[];
    final linkedIds = {for (final l in linked) l.outcome.id};
    final query = _controller.text.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ClarifyFieldLabel('OUTCOMES'),
        const SizedBox(height: 8),
        // Error before absence: a link list that failed to load is not the
        // same as a Capture with no Outcomes yet, and must not be rendered as
        // one (widgets/state_surfaces.dart).
        AsyncList<CarvedOutcome>(
          asyncValue: linkedAsync,
          emptyTitle: 'No Outcomes yet',
          emptyBuilder: (_) => const _NoOutcomesYet(),
          dataBuilder: (context, items) => Column(
            children: [
              for (final item in items)
                _LinkedOutcomeRow(
                  key: Key('linked_outcome_${item.outcome.id}'),
                  item: item,
                  enabled: !_busy,
                  onUnlink: () => _unlink(item.outcome.id),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('capture_outcome_field'),
          controller: _controller,
          enabled: !_busy,
          onChanged: _onQueryChanged,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Link or create an Outcome',
            hintText: 'Start typing…',
            border: OutlineInputBorder(borderRadius: _radiusChip),
            contentPadding:
                EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
        ),
        if (query.isNotEmpty) ...[
          const SizedBox(height: 8),
          _Suggestions(
            query: query,
            // An Outcome this Capture already claims is not a merge candidate
            // — offering it would be a no-op row.
            matches: [
              for (final m in _matches)
                if (!linkedIds.contains(m.id)) m,
            ],
            enabled: !_busy,
            onCreate: () => _carve(query),
            onMerge: _merge,
          ),
        ],
        const SizedBox(height: 24),
        _VerdictFooter(
          hasOutcomes: linked.isNotEmpty,
          enabled: !_busy,
          onPressed: () => _commitVerdict(hasOutcomes: linked.isNotEmpty),
        ),
      ],
    );
  }
}

/// The empty state for a Capture nothing has been carved from yet. Says what
/// the field below does rather than merely reporting the absence.
class _NoOutcomesYet extends StatelessWidget {
  const _NoOutcomesYet();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: Text(
        'No Outcomes yet. Link this Capture to one, or create one below.',
        style: TextStyle(fontSize: 13, color: _textGray),
      ),
    );
  }
}

/// One Outcome the Capture claims, with its provenance chip and unlink ✕.
class _LinkedOutcomeRow extends StatelessWidget {
  const _LinkedOutcomeRow({
    super.key,
    required this.item,
    required this.enabled,
    required this.onUnlink,
  });

  final CarvedOutcome item;
  final bool enabled;
  final VoidCallback onUnlink;

  @override
  Widget build(BuildContext context) {
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
                if (item.isMerged) ...[
                  const SizedBox(height: 4),
                  _ProvenanceChip(captureCount: item.captureCount),
                ],
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            color: _labelGray,
            tooltip: 'Unlink',
            onPressed: enabled ? onUnlink : null,
          ),
        ],
      ),
    );
  }
}

/// "from N Captures" — the merge marker on an Outcome several Captures
/// clarified into.
class _ProvenanceChip extends StatelessWidget {
  const _ProvenanceChip({required this.captureCount});

  final int captureCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: _accentBlue.withValues(alpha: 0.08),
        borderRadius: _radiusChip,
      ),
      child: Text(
        'from $captureCount Captures',
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: _accentBlue,
        ),
      ),
    );
  }
}

/// The autocomplete list under the field: the create row first, then title
/// matches to merge into.
class _Suggestions extends StatelessWidget {
  const _Suggestions({
    required this.query,
    required this.matches,
    required this.enabled,
    required this.onCreate,
    required this.onMerge,
  });

  final String query;
  final List<Todo> matches;
  final bool enabled;
  final VoidCallback onCreate;
  final void Function(Todo) onMerge;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: _radiusSurface,
        border: Border.all(color: _borderGray),
      ),
      child: Column(
        children: [
          // Create sits first and is always present: the user has typed
          // something no existing Outcome may match, and the field must never
          // dead-end.
          ListTile(
            key: const Key('capture_outcome_create'),
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
            enabled: enabled,
            onTap: enabled ? onCreate : null,
          ),
          for (final match in matches)
            ListTile(
              key: Key('capture_outcome_match_${match.id}'),
              dense: true,
              leading: const Icon(Icons.link, size: 18, color: _textGray),
              title: Text(
                match.title,
                style: const TextStyle(fontSize: 14),
              ),
              enabled: enabled,
              onTap: enabled ? () => onMerge(match) : null,
            ),
        ],
      ),
    );
  }
}

/// One primary button whose label — and meaning — swap on the linked count.
///
/// Not two buttons behind a conditional: the user makes exactly one verdict
/// here, and the swap is what keeps Discard from reading as a destructive
/// escape hatch sitting permanently beside the happy path.
class _VerdictFooter extends StatelessWidget {
  const _VerdictFooter({
    required this.hasOutcomes,
    required this.enabled,
    required this.onPressed,
  });

  final bool hasOutcomes;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        key: const Key('capture_verdict'),
        onPressed: enabled ? onPressed : null,
        style: FilledButton.styleFrom(
          backgroundColor: hasOutcomes ? _accentBlue : _discardGray,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: const RoundedRectangleBorder(borderRadius: _radiusButton),
        ),
        child: Text(
          hasOutcomes ? 'Done with this Capture' : 'Discard Capture',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
