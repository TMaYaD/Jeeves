import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../database/gtd_database.dart' show Tag;
import '../../../models/search_result.dart';
import '../../../widgets/meta_chip.dart';
import '../../../widgets/outcome_row.dart';

/// A single row in the search result list.
class SearchResultTile extends StatelessWidget {
  const SearchResultTile({super.key, required this.result});

  final SearchResult result;

  @override
  Widget build(BuildContext context) {
    final isDone = result.todo?.doneAt != null;

    return OutcomeRow(
      title: result.title,
      titleStyle: TextStyle(
        fontWeight: result.matchedFields.contains(SearchMatchField.title)
            ? FontWeight.w700
            : FontWeight.w500,
      ),
      // Captures open clarification; Outcomes open their full record.
      onTap: () => context.push(
        result.isCapture ? '/inbox/${result.id}/clarify' : '/task/${result.id}',
      ),
      secondary: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (result.matchSnippet != null)
            Text(
              result.matchSnippet!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
            ),
          _MatchHint(matchedFields: result.matchedFields, tags: result.tags),
        ],
      ),
      trailing: result.isCapture
          ? const MetaChip(
              icon: Icons.inbox_outlined,
              label: 'Inbox',
              color: Color(0xFF2563EB),
            )
          : isDone
          ? const MetaChip(
              icon: Icons.check_circle_outline,
              label: 'Done',
              color: Color(0xFF6B7280),
            )
          : result.tags.any((t) => t.type == 'person')
          ? const MetaChip(
              icon: Icons.hourglass_empty,
              label: 'Waiting',
              color: Color(0xFFD97706),
            )
          : const SizedBox.shrink(),
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
