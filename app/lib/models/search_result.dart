import '../database/gtd_database.dart' show Todo, Tag;

/// Which field(s) of a task matched the search query.
enum SearchMatchField { title, notes, projectTag, contextTag, areaTag }

/// A search hit: the matching task, its tags, and metadata about what matched.
class SearchResult {
  const SearchResult({
    required this.todo,
    required this.tags,
    required this.matchedFields,
    this.matchSnippet,
  });

  final Todo todo;
  final List<Tag> tags;

  /// Fields that contained the search term.
  final Set<SearchMatchField> matchedFields;

  /// Short excerpt from notes around the hit position (≤ 120 chars).
  final String? matchSnippet;
}
