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
  List<BatchAddCandidate> addable = const [],
}) {
  return showModalBottomSheet<BatchSheetChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => BatchSuggestionSheet(
      suggestion: suggestion,
      titleFor: titleFor,
      clock: clock,
      addable: addable,
    ),
  );
}

/// An Outcome of the suggestion's context that could join it.
typedef BatchAddCandidate = ({String outcomeId, String title, int minutes});

class BatchSuggestionSheet extends StatefulWidget {
  const BatchSuggestionSheet({
    super.key,
    required this.suggestion,
    required this.titleFor,
    required this.clock,
    this.addable = const [],
  });

  final BatchSuggestion suggestion;
  final String Function(String outcomeId) titleFor;
  final String Function(DateTime time) clock;

  /// Same-context Outcomes the Edit view may add.
  final List<BatchAddCandidate> addable;

  @override
  State<BatchSuggestionSheet> createState() => _BatchSuggestionSheetState();
}

class _BatchSuggestionSheetState extends State<BatchSuggestionSheet> {
  late final Map<String, int> _minutesById = {
    for (final member in widget.suggestion.members)
      member.outcomeId: member.minutes,
    for (final candidate in widget.addable)
      candidate.outcomeId: candidate.minutes,
  };
  late final List<String> _memberIds = [
    for (final member in widget.suggestion.members) member.outcomeId,
  ];
  bool _editing = false;

  int get _totalMinutes =>
      _memberIds.fold(0, (sum, id) => sum + _minutesById[id]!);

  int get _gapMinutes => widget.suggestion.gapEnd
      .difference(widget.suggestion.gapStart)
      .inMinutes;

  /// Whether [candidate] would still fit the gap alongside the members.
  bool _fits(BatchAddCandidate candidate) =>
      _totalMinutes + candidate.minutes <= _gapMinutes;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: _editing ? _editView(context) : _summaryView(context),
      ),
    );
  }

  Widget _summaryView(BuildContext context) {
    final suggestion = widget.suggestion;
    final end = suggestion.gapStart.add(Duration(minutes: _totalMinutes));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('A small suggestion, sir.',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          '${_memberIds.length} ${suggestion.contextName} errands, '
          '${_totalMinutes}m together, would fit the gap at '
          '${widget.clock(suggestion.gapStart)}, as one sprint with no break '
          'between them.',
          key: const Key('batch_suggestion_summary'),
          style: TextStyle(fontSize: 14, color: Colors.grey[700]),
        ),
        const SizedBox(height: 12),
        for (final id in _memberIds)
          ListTile(
            key: Key('batch_suggestion_member_$id'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(widget.titleFor(id),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Text('${_minutesById[id]}m'),
          ),
        const SizedBox(height: 4),
        Text(
          'Same context (${suggestion.contextName}), each '
          '${batchMemberMaxMinutes}m or less · '
          '${widget.clock(suggestion.gapStart)}–${widget.clock(end)}',
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            TextButton(
              key: const Key('batch_suggestion_not_today'),
              onPressed: () => Navigator.of(context)
                  .pop(BatchSheetChoice.declined(_memberIds)),
              child: const Text('Not today'),
            ),
            const Spacer(),
            TextButton(
              key: const Key('batch_suggestion_edit'),
              onPressed: () => setState(() => _editing = true),
              child: const Text('Edit'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const Key('batch_suggestion_accept'),
              onPressed: _memberIds.length >= 2
                  ? () => Navigator.of(context)
                      .pop(BatchSheetChoice.accepted(_memberIds))
                  : null,
              child: const Text('Very good'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _editView(BuildContext context) {
    final suggestion = widget.suggestion;
    final addable = [
      for (final candidate in widget.addable)
        if (!_memberIds.contains(candidate.outcomeId)) candidate,
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Whom shall I include, sir?',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Each keeps its own tile. Remove any, or add another '
          '${suggestion.contextName} Outcome.',
          style: TextStyle(fontSize: 14, color: Colors.grey[700]),
        ),
        const SizedBox(height: 12),
        for (final id in _memberIds)
          ListTile(
            key: Key('batch_edit_member_$id'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(widget.titleFor(id),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${_minutesById[id]}m'),
            trailing: TextButton(
              key: Key('batch_edit_remove_$id'),
              onPressed: () => setState(() => _memberIds.remove(id)),
              child: const Text('Remove'),
            ),
          ),
        for (final candidate in addable)
          ListTile(
            key: Key('batch_edit_candidate_${candidate.outcomeId}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(candidate.title,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${candidate.minutes}m'),
            trailing: TextButton(
              key: Key('batch_edit_add_${candidate.outcomeId}'),
              onPressed: _fits(candidate)
                  ? () => setState(() => _memberIds.add(candidate.outcomeId))
                  : null,
              child: const Text('Add'),
            ),
          ),
        const SizedBox(height: 16),
        Row(
          children: [
            TextButton(
              key: const Key('batch_edit_back'),
              onPressed: () => setState(() => _editing = false),
              child: const Text('Back'),
            ),
            const Spacer(),
            FilledButton(
              key: const Key('batch_edit_accept'),
              onPressed: _memberIds.length >= 2
                  ? () => Navigator.of(context)
                      .pop(BatchSheetChoice.accepted(_memberIds))
                  : null,
              child: const Text('Very good'),
            ),
          ],
        ),
      ],
    );
  }
}
