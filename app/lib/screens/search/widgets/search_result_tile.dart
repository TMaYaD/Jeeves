import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../database/gtd_database.dart' show Tag;
import '../../../models/search_result.dart';
import '../../../models/todo.dart' show GtdState;

/// A single row in the search result list.
class SearchResultTile extends StatelessWidget {
  const SearchResultTile({super.key, required this.result});

  final SearchResult result;

  @override
  Widget build(BuildContext context) {
    final todo = result.todo;

    final isDone = todo.doneAt != null;

    return InkWell(
      onTap: () => context.push('/task/${todo.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    todo.title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: result.matchedFields
                              .contains(SearchMatchField.title)
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: const Color(0xFF1A1A2E),
                    ),
                  ),
                  if (result.matchSnippet != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      result.matchSnippet!,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF6B7280),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  _MatchHint(
                    matchedFields: result.matchedFields,
                    tags: result.tags,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (isDone)
              const _DoneChip()
            else if (todo.waitingFor != null)
              const _WaitingChip()
            else
              _StateChip(state: GtdState.fromString(todo.state)),
          ],
        ),
      ),
    );
  }
}

class _MatchHint extends StatelessWidget {
  const _MatchHint({required this.matchedFields, required this.tags});

  final Set<SearchMatchField> matchedFields;
  final List<Tag> tags;

  @override
  Widget build(BuildContext context) {
    final hints = <String>[];

    if (matchedFields.contains(SearchMatchField.notes)) {
      hints.add('in notes');
    }
    if (matchedFields.contains(SearchMatchField.projectTag)) {
      final project =
          tags.where((t) => t.type == 'project').firstOrNull;
      if (project != null) hints.add('project: ${project.name}');
    }
    if (matchedFields.contains(SearchMatchField.contextTag)) {
      final ctxNames = tags
          .where((t) => t.type == 'context')
          .map((t) => '@${t.name}')
          .join(', ');
      if (ctxNames.isNotEmpty) hints.add(ctxNames);
    }
    if (matchedFields.contains(SearchMatchField.areaTag)) {
      final area = tags.where((t) => t.type == 'area').firstOrNull;
      if (area != null) hints.add('area: ${area.name}');
    }

    if (hints.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        hints.join(' · '),
        style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
      ),
    );
  }
}

class _DoneChip extends StatelessWidget {
  const _DoneChip();

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFF6B7280);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: const Text(
        'Done',
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}

class _WaitingChip extends StatelessWidget {
  const _WaitingChip();

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFFD97706);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: const Text(
        'Waiting',
        style:
            TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.state});

  final GtdState state;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      GtdState.nextAction => ('Next', const Color(0xFF16A34A)),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}
