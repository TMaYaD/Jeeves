/// What happened to your data, in plain language.
///
/// Reachable only when there is something to report, and it says so and stops.
/// **No buttons of any kind**: there are no alarm resolutions yet (#575), and a
/// control that did nothing would be worse than none — the whole reason this
/// screen exists is that the previous surface, a permanently red icon, was a
/// signal the user could not act on.
///
/// Voice and vocabulary are `sync_health_copy.dart`'s, and both are asserted by
/// test. Nothing here composes a sentence of its own.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/sync_health_detail_provider.dart';
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
        for (final condition in entry.value) _ConditionRow(condition: condition),
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

/// One condition: a sentence, when it happened, and nothing to press.
///
/// Every machine string — the stored code, the member id, the row id, the
/// engine's own `detail` — lives inside the expandable, so the collapsed screen
/// carries none of it (#584 AC-4).
class _ConditionRow extends StatelessWidget {
  const _ConditionRow({required this.condition});
  final SyncHealthCondition condition;

  @override
  Widget build(BuildContext context) {
    return Theme(
      // Flat, like the task-detail history section: an expander is the only tap
      // target on this screen and it should not read as a card.
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        title: Text(
          condition.sentence,
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
