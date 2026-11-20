import 'package:flutter/material.dart';

import '../../models/batch_suggestion.dart';

/// What the user answered to a small-task suggestion.
class BatchSheetChoice {
  const BatchSheetChoice.accepted(this.memberIds) : isAccepted = true;
  const BatchSheetChoice.declined(this.memberIds) : isAccepted = false;

  /// "Very good" (true) or "Not today" (false).
  final bool isAccepted;

  /// The Outcomes the answer is about, in the order they would run.
  final List<String> memberIds;
}

/// Opens the small-task suggestion sheet and returns the answer, or null when
/// it was dismissed (nothing then changes).
///
/// [titleFor] names an Outcome; [clock] formats a time the way the timeline
/// does.
Future<BatchSheetChoice?> showBatchSuggestionSheet(
  BuildContext context, {
  required BatchSuggestion suggestion,
  required String Function(String outcomeId) titleFor,
  required String Function(DateTime time) clock,
}) {
  return showModalBottomSheet<BatchSheetChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => BatchSuggestionSheet(
      suggestion: suggestion,
      titleFor: titleFor,
      clock: clock,
    ),
  );
}

class BatchSuggestionSheet extends StatelessWidget {
  const BatchSuggestionSheet({
    super.key,
    required this.suggestion,
    required this.titleFor,
    required this.clock,
  });

  final BatchSuggestion suggestion;
  final String Function(String outcomeId) titleFor;
  final String Function(DateTime time) clock;

  @override
  Widget build(BuildContext context) {
    final members = suggestion.members;
    final ids = [for (final member in members) member.outcomeId];
    final end = suggestion.gapStart.add(Duration(minutes: suggestion.totalMinutes));
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('A small suggestion, sir.',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '${members.length} ${suggestion.contextName} errands, '
              '${suggestion.totalMinutes}m together, would fit the gap at '
              '${clock(suggestion.gapStart)}, as one sprint with no break '
              'between them.',
              key: const Key('batch_suggestion_summary'),
              style: TextStyle(fontSize: 14, color: Colors.grey[700]),
            ),
            const SizedBox(height: 12),
            for (final member in members)
              ListTile(
                key: Key('batch_suggestion_member_${member.outcomeId}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(titleFor(member.outcomeId),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: Text('${member.minutes}m'),
              ),
            const SizedBox(height: 4),
            Text(
              'Same context (${suggestion.contextName}), each '
              '${batchMemberMaxMinutes}m or less · '
              '${clock(suggestion.gapStart)}–${clock(end)}',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                TextButton(
                  key: const Key('batch_suggestion_not_today'),
                  onPressed: () => Navigator.of(context)
                      .pop(BatchSheetChoice.declined(ids)),
                  child: const Text('Not today'),
                ),
                const Spacer(),
                const TextButton(
                  key: Key('batch_suggestion_edit'),
                  onPressed: null,
                  child: Text('Edit'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('batch_suggestion_accept'),
                  onPressed: () => Navigator.of(context)
                      .pop(BatchSheetChoice.accepted(ids)),
                  child: const Text('Very good'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
