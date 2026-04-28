/// DAO for universal search across todos and tags.
///
/// Implemented as a plain class (no @DriftAccessor) so no code-generation
/// step is required.  All queries run against the local SQLite store and are
/// fully offline-capable.
library;

import 'package:drift/drift.dart';

import '../../models/search_query.dart';
import '../../models/search_result.dart';
import '../gtd_database.dart';

class SearchDao {
  SearchDao(this._db);

  final GtdDatabase _db;

  /// Returns a reactive stream of search results for [userId] matching [query].
  ///
  /// The stream re-emits whenever the todos, todo_tags, or tags tables change,
  /// so results stay up-to-date with offline writes and sync'd data.
  ///
  /// When [query.isEmpty] is true, an empty list is returned immediately.
  Stream<List<SearchResult>> search(String userId, SearchQuery query) {
    if (query.isEmpty) return Stream.value([]);

    // Build a LEFT OUTER JOIN across all three tables so we get:
    //   • todos without tags (tag columns are null)
    //   • todos with one or more tags (one row per tag)
    final q = _db.select(_db.todos).join([
      leftOuterJoin(
        _db.todoTags,
        _db.todoTags.todoId.equalsExp(_db.todos.id),
      ),
      leftOuterJoin(
        _db.tags,
        _db.tags.id.equalsExp(_db.todoTags.tagId),
      ),
    ]);

    // ---- Structured filters applied at the SQL level ----

    Expression<bool> where = _db.todos.userId.equals(userId);

    if (query.states.isNotEmpty) {
      // Explicit state selection overrides includeDone
      where = where &
          _db.todos.state.isIn(
            query.states.map((s) => s.value).toList(),
          );
    } else if (!query.includeDone) {
      where = where & _db.todos.doneAt.isNull();
    }

    if (query.energyLevels.isNotEmpty) {
      where = where &
          _db.todos.energyLevel.isIn(query.energyLevels.toList());
    }

    if (query.dueDateAfter != null) {
      where = where &
          _db.todos.dueDate.isBiggerOrEqualValue(query.dueDateAfter!);
    }
    if (query.dueDateBefore != null) {
      where = where &
          _db.todos.dueDate.isSmallerOrEqualValue(query.dueDateBefore!);
    }

    if (query.timeEstimateMaxMinutes != null) {
      where = where &
          (_db.todos.timeEstimate.isNull() |
              _db.todos.timeEstimate
                  .isSmallerOrEqualValue(query.timeEstimateMaxMinutes!));
    }

    q.where(where);

    // Stable ordering: most-recently-updated first, then by creation time and
    // id to break ties across todos with the same updatedAt.
    q.orderBy([
      OrderingTerm(
        expression: _db.todos.updatedAt,
        mode: OrderingMode.desc,
      ),
      OrderingTerm(
        expression: _db.todos.createdAt,
        mode: OrderingMode.desc,
      ),
      OrderingTerm(expression: _db.todos.id),
    ]);

    return q.watch().map((rows) => _processRows(rows, query));
  }

  // ---------------------------------------------------------------------------
  // Row processing
  // ---------------------------------------------------------------------------

  List<SearchResult> _processRows(
    List<TypedResult> rows,
    SearchQuery query,
  ) {
    // Group rows by todo id, collecting all tags for each todo.
    // The ordered list preserves the SQL ordering.
    final Map<String, _TodoWithTags> grouped = {};
    final List<String> orderedIds = [];

    for (final row in rows) {
      final todo = row.readTable(_db.todos);
      final tag = row.readTableOrNull(_db.tags);

      if (!grouped.containsKey(todo.id)) {
        grouped[todo.id] = _TodoWithTags(todo: todo, tags: []);
        orderedIds.add(todo.id);
      }
      if (tag != null) {
        grouped[todo.id]!.tags.add(tag);
      }
    }

    final term = query.text.toLowerCase().trim();
    final results = <SearchResult>[];

    for (final id in orderedIds) {
      final entry = grouped[id]!;
      final todo = entry.todo;
      final tags = entry.tags;

      // Tag-scope filter: if the caller has active tag-cloud IDs, only return
      // todos that carry at least one of those tags.
      if (query.tagIds.isNotEmpty) {
        final todoTagIds = tags.map((t) => t.id).toSet();
        if (!query.tagIds.any(todoTagIds.contains)) continue;
      }

      // Text filter applied in Dart so the SQL query stays simple and
      // compatible with PowerSync views.
      Set<SearchMatchField> matchedFields;
      String? snippet;

      if (term.isNotEmpty) {
        final titleHit = todo.title.toLowerCase().contains(term);
        final notesHit = todo.notes?.toLowerCase().contains(term) ?? false;
        final tagHit =
            tags.any((t) => t.name.toLowerCase().contains(term));

        if (!titleHit && !notesHit && !tagHit) continue;

        matchedFields = _computeMatchedFields(todo, tags, term);
        snippet = notesHit ? _extractSnippet(todo.notes, term) : null;
      } else {
        matchedFields = const {};
        snippet = null;
      }

      results.add(SearchResult(
        todo: todo,
        tags: tags,
        matchedFields: matchedFields,
        matchSnippet: snippet,
      ));
    }

    return results;
  }

  Set<SearchMatchField> _computeMatchedFields(
    Todo todo,
    List<Tag> tags,
    String term,
  ) {
    final fields = <SearchMatchField>{};

    if (todo.title.toLowerCase().contains(term)) {
      fields.add(SearchMatchField.title);
    }
    if (todo.notes?.toLowerCase().contains(term) ?? false) {
      fields.add(SearchMatchField.notes);
    }

    for (final tag in tags) {
      if (!tag.name.toLowerCase().contains(term)) continue;
      switch (tag.type) {
        case 'project':
          fields.add(SearchMatchField.projectTag);
        case 'area':
          fields.add(SearchMatchField.areaTag);
        default:
          fields.add(SearchMatchField.contextTag);
      }
    }

    return fields;
  }

  String? _extractSnippet(String? notes, String term) {
    if (notes == null) return null;
    final lower = notes.toLowerCase();
    final idx = lower.indexOf(term);
    if (idx < 0) return null;
    const window = 40;
    const maxLen = 120;
    final start = (idx - window).clamp(0, notes.length);
    final end = (start + maxLen).clamp(0, notes.length);
    final snippet = notes.substring(start, end);
    final prefix = start > 0 ? '…' : '';
    final suffix = end < notes.length ? '…' : '';
    return '$prefix$snippet$suffix';
  }
}

class _TodoWithTags {
  _TodoWithTags({required this.todo, required this.tags});
  final Todo todo;
  final List<Tag> tags;
}
