/// What happened to your data, in plain language.
///
/// Reachable only when there is something to report, and it says so and stops.
/// **A condition offers the decisions its kind has, and nothing else**: a
/// button that did nothing would be worse than none — the whole reason this
/// screen exists is that the previous surface, a permanently red icon, was a
/// signal the user could not act on. There is no dismiss and no retry: a
/// condition is settled by a decision, and silence is not a decision.
///
/// Voice and vocabulary are `sync_health_copy.dart`'s, and both are asserted by
/// test. Nothing here composes a sentence of its own.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/sync_health_detail_provider.dart';
import '../../sync/alarm_resolution.dart';
import '../../sync/sync_condition_class.dart';
import '../../sync/sync_health_detail.dart';
import '../../widgets/app_title_bar/app_title_bar.dart';
import 'sync_health_copy.dart';

class SyncHealthScreen extends ConsumerWidget {
  const SyncHealthScreen({super.key});

  static const String routePath = '/sync-health';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userId = ref.watch(currentUserIdProvider);
    final conditions = ref.watch(syncHealthDetailProvider).value ?? const [];

    final needsAttention = [
      for (final condition in conditions)
        if (classOfCondition(condition) == SyncConditionClass.actionable) condition,
    ];
    final handled = [
      for (final condition in conditions)
        if (classOfCondition(condition) == SyncConditionClass.reported) condition,
    ];

    return Scaffold(
      appBar: const AppTitleBar(title: syncHealthScreenTitle),
      backgroundColor: Colors.white,
      body: ListView(
        children: [
          // The whole justification for a visible-but-calm indicator: a user who
          // has never seen one needs telling, once and plainly, that this is
          // worth reading and needs nothing from them.
          if (needsAttention.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 20, 16, 4),
              child: Text(
                syncHealthAllHandledExplanation,
                style: TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
              ),
            ),
          if (needsAttention.isNotEmpty)
            ..._group(
              heading: syncHealthNeedsAttentionHeading,
              conditions: needsAttention,
              userId: userId,
            ),
          if (handled.isNotEmpty)
            ..._group(
              heading: syncHealthHandledHeading,
              conditions: handled,
              userId: userId,
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// One group, split into its per-Workspace sections.
  ///
  /// The Workspace overline is only drawn where the id has an honest label: an
  /// unrecognised one shows nothing rather than a raw uuid.
  List<Widget> _group({
    required String heading,
    required List<SyncHealthCondition> conditions,
    required String userId,
  }) {
    final byWorkspace = <String, List<SyncHealthCondition>>{};
    for (final condition in conditions) {
      byWorkspace.putIfAbsent(condition.workspaceId, () => []).add(condition);
    }
    return [
      const Divider(height: 1, color: Color(0xFFF3F4F6)),
      _overline(heading, const Color(0xFF374151)),
      for (final entry in byWorkspace.entries) ...[
        ?_workspaceOverline(entry.key, userId),
        for (final condition in entry.value)
          _ConditionRow(key: conditionRowKey(condition), condition: condition),
      ],
    ];
  }

  Widget? _workspaceOverline(String workspaceId, String userId) {
    final label = syncWorkspaceLabelFor(workspaceId, userId);
    return label == null ? null : _overline(label, const Color(0xFF9CA3AF));
  }

  static Widget _overline(String text, Color color) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
            color: color,
          ),
        ),
      );
}

/// The one plain sentence a condition is told as.
///
/// The copy-side twin of `classOfCondition`, and the reason [SyncHealthCondition]
/// carries no sentence of its own: the sync tier says *what happened* and *what
/// class it is*, and the words are resolved here, from the stored code and the
/// side of the store it came from. `sync_health_copy.dart` still owns every
/// string — this only picks which of its two lookups applies.
String sentenceForCondition(SyncHealthCondition condition) =>
    switch (condition.source) {
      SyncConditionSource.standingCondition => sentenceForAlarmCode(condition.code),
      SyncConditionSource.refusedItem => sentenceForRefusalCode(condition.code),
    };

/// What identifies a row to the element tree, so an expander stays attached to
/// the condition it was opened on.
///
/// `ExpansionTile` owns its expanded state, and without a key Flutter matches
/// old children to new ones **by position**: a condition arriving, healing, or
/// moving between the two groups would slide one row's open detail under a
/// different row's sentence.
///
/// All three parts are load-bearing, because `rowId` alone is not unique here.
/// It is a table row id, and the screen folds two tables across two Workspaces
/// into one list — an alarm and a refusal can share id 1, and duplicate sibling
/// keys are a crash rather than a mis-match.
Key conditionRowKey(SyncHealthCondition condition) =>
    ValueKey('${condition.workspaceId}/${condition.source.name}/${condition.rowId}');

/// The words on the button that settles a condition.
///
/// The copy-side twin of [sentenceForCondition], and the same rule: the screen
/// picks which of the copy file's lookups applies and composes nothing.
String resolutionLabelForCondition(
  SyncHealthCondition condition,
  AlarmResolution resolution,
) =>
    switch (condition.source) {
      SyncConditionSource.standingCondition =>
        resolutionLabelForAlarmCode(condition.code, resolution),
      SyncConditionSource.refusedItem => syncHealthRejectRefusedItemLabel,
    };

/// One condition: a sentence, when it happened, and the decisions it may be
/// given.
///
/// Every machine string — the stored code, the member id, the row id, the
/// engine's own `detail` — lives inside the expandable, so the collapsed screen
/// carries none of it (#584 AC-4).
///
/// **The buttons sit below the tile, not inside it.** The tile's own touch is
/// the expander, and a button nested in it would be competing with the expander
/// for the same touch — so the decisions are a sibling of the tile, under the
/// sentence they belong to.
class _ConditionRow extends ConsumerStatefulWidget {
  const _ConditionRow({super.key, required this.condition});
  final SyncHealthCondition condition;

  @override
  ConsumerState<_ConditionRow> createState() => _ConditionRowState();
}

class _ConditionRowState extends ConsumerState<_ConditionRow> {
  /// The decision whose call is running, if any.
  ///
  /// One at a time: the button that is running is disabled, and the row is
  /// left showing what it is doing rather than what it could do.
  AlarmResolution? _running;

  /// The failure of the last decision, if it could not be finished.
  ///
  /// **A decision that fails is not a decision.** The button is re-enabled and
  /// the row says so, because a user who tapped a button and saw nothing
  /// happen cannot tell whether their answer was recorded — and the condition
  /// is still standing, so there is something left for them to do.
  String? _failure;

  Future<void> _resolve(AlarmResolution resolution) async {
    setState(() {
      _running = resolution;
      _failure = null;
    });
    try {
      await ref.read(syncAlarmResolverProvider)(widget.condition, resolution);
    } on Object catch (error) {
      // The reason belongs in the log, not on the page: the user can act on
      // "it did not happen" and on nothing else.
      debugPrint('sync health: recording a decision failed — $error');
      if (mounted) {
        setState(() => _failure = syncHealthResolutionFailedSentence);
      }
    } finally {
      // Re-enabled even when the call failed: the condition is still standing,
      // and the user is owed the chance to try again.
      if (mounted) setState(() => _running = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final condition = widget.condition;
    return Column(
      // Stretched, so the expander keeps the full width of the screen rather
      // than shrinking to the length of its own sentence.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Theme(
          // Flat, like the task-detail history section: an expander is the only
          // tap target on this screen and it should not read as a card.
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 16),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            title: Text(
              sentenceForCondition(condition),
              style: const TextStyle(fontSize: 14, color: Color(0xFF374151)),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _whenLine(condition),
                style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
              ),
            ),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: SelectableText(
                  _technicalDetail(condition),
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF9CA3AF),
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ),
        ),
        if (condition.resolutionInFlight)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Two pixels, the thinnest thing the design system has, and the
                // blue of the Syncing indicator: a decision in flight is a
                // transient state, and amber is spent on the calm one.
                SizedBox(
                  height: 2,
                  child: LinearProgressIndicator(
                    minHeight: 2,
                    color: Color(0xFF2563EB),
                    backgroundColor: Color(0xFFE5E7EB),
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  syncHealthResolutionInFlightSentence,
                  style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                ),
              ],
            ),
          )
        else if (condition.resolutions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 16, 12),
            child: Wrap(
              spacing: 4,
              children: [
                for (final resolution in condition.resolutions)
                  TextButton(
                    onPressed: _running == resolution
                        ? null
                        : () => _resolve(resolution),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF2563EB),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: Text(
                      resolutionLabelForCondition(condition, resolution),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
              ],
            ),
          ),
        // Below the buttons, in the same plain voice as everything else on this
        // screen: what the user needs to know is that their answer did not take
        // effect, and that they can try again.
        if (_failure != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              _failure!,
              style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
            ),
          ),
      ],
    );
  }
}

/// When it happened, and — for a refused item — whether it was applied later.
///
/// "Re-admitted" is marked rather than hidden: the difference between "arrived
/// out of order" and "withheld and still missing" is exactly what someone
/// reading this page is trying to establish (#584 AC-2).
String _whenLine(SyncHealthCondition condition) {
  final parts = <String>[];
  if (condition.reAdmitted) {
    parts.add('Applied later, on ${_date(condition.lastSeenAt)}');
  } else {
    parts.add('First seen ${_date(condition.firstSeenAt)}');
    if (_date(condition.lastSeenAt) != _date(condition.firstSeenAt)) {
      parts.add('most recently ${_date(condition.lastSeenAt)}');
    }
  }
  if (condition.occurrenceCount > 1) {
    parts.add('${condition.occurrenceCount} times');
  }
  return parts.join(' · ');
}

String _technicalDetail(SyncHealthCondition condition) {
  final lines = <String>[
    condition.code,
    'row ${condition.rowId}',
    if (condition.memberId != null) 'member ${condition.memberId}',
    if (condition.detail.isNotEmpty) condition.detail,
  ];
  return lines.join('\n');
}

String _date(DateTime when) {
  final local = when.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}
