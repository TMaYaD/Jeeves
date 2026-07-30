/// DAO for universal search across Outcomes, Captures and tags.
///
/// Implemented as a plain class (no @DriftAccessor) so no code-generation
/// step is required.  All queries run against the local SQLite store and are
/// fully offline-capable.
///
/// Search spans both halves of the ADR-0006 split: clarified Outcomes
/// (`todos`, tagged via `todo_tags`) and Inbox Captures (`captures`, tagged via
/// `capture_tags` hints). Only *unclarified* Captures are searched — a
/// clarified one is already represented by the Outcome it produced, so
/// including it would return the same thing twice.
library;

import 'dart:async';

import 'package:drift/drift.dart';

import '../../models/search_query.dart';
import '../../models/search_result.dart';
import '../gtd_database.dart';
import 'todo_dao.dart' show TodoDao;

class SearchDao {
  SearchDao(this._db);

  final GtdDatabase _db;

  // Effective, Action-grain energy / time-estimate (ADR-0001 story 7, D2):
  // the current Action's value with the Outcome column as fallback. Structured
  // filters match on these — and results hydrate through them — so search
  // ranks and filters an Outcome by the effort of doing its *current* Action,
  // falling through to the Outcome column for Actionless / legacy rows. The
  // outer table alias is Drift's default for the main table of a join: the
  // table's own name, `todos`. `Precedence.primary` marks the COALSECE(...)
  // as an atomic operand so surrounding `IN` / `<=` / `IS NULL` need no parens.
  static final Expression<String> _effectiveEnergyLevel =
      CustomExpression<String>(
    TodoDao.effectiveEnergyLevelSql('todos'),
    precedence: Precedence.primary,
  );
  static final Expression<int> _effectiveTimeEstimate = CustomExpression<int>(
    TodoDao.effectiveTimeEstimateSql('todos'),
    precedence: Precedence.primary,
  );

  /// Returns a reactive stream of search results matching [query].
  ///
  /// The stream re-emits whenever the todos, captures, their junctions, or the
  /// tags table changes, so results stay up-to-date with offline writes and
  /// sync'd data. Outcome hits come first, then Inbox Captures.
  ///
  /// When [query.isEmpty] is true, an empty list is returned immediately.
  Stream<List<SearchResult>> search(SearchQuery query) {
    if (query.isEmpty) return Stream.value([]);

    return _combineLatest(
      _outcomeRows(query).map((rows) => _processRows(rows, query)),
      _captureRows(query).map((rows) => _processCaptureRows(rows, query)),
      (outcomes, captures) => [...outcomes, ...captures],
    );
  }

  /// The Inbox-Capture leg of [search].
  ///
  /// Captures carry no energy level, time estimate or due date — those are
  /// Outcome attributes (ADR-0006) — so any structured attribute filter
  /// excludes them entirely rather than matching them vacuously. Text and
  /// tag-hint search is unaffected, which is what keeps an unclarified thought
  /// findable. `includeDone` is irrelevant: a Capture is never done.
  Stream<List<TypedResult>> _captureRows(SearchQuery query) {
    final filtersOutcomeAttributes = query.energyLevels.isNotEmpty ||
        query.dueDateAfter != null ||
        query.dueDateBefore != null ||
        query.timeEstimateMaxMinutes != null;
    if (filtersOutcomeAttributes) return Stream.value(const []);

    final q = _db.select(_db.captures).join([
      leftOuterJoin(
        _db.captureTags,
        _db.captureTags.captureId.equalsExp(_db.captures.id),
      ),
      leftOuterJoin(
        _db.tags,
        _db.tags.id.equalsExp(_db.captureTags.tagId),
      ),
    ]);

    // Only the Inbox: a clarified Capture is already represented by its
    // Outcome, so including it would return the same thing twice.
    q.where(_db.captures.clarifiedAt.isNull());

    q.orderBy([
      OrderingTerm(
        expression: _db.captures.createdAt,
        mode: OrderingMode.desc,
      ),
      OrderingTerm(expression: _db.captures.id),
    ]);

    return q.watch();
  }

  Stream<List<TypedResult>> _outcomeRows(SearchQuery query) {
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

    // Hydrate the effective (Action-grain) metadata alongside the row so the
    // returned Todo carries the current Action's energy/time (see
    // [_groupAndFilter]).
    q.addColumns([_effectiveEnergyLevel, _effectiveTimeEstimate]);

    // ---- Structured filters applied at the SQL level ----

    Expression<bool> where = const Constant(true);

    if (!query.includeDone) {
      where = where & _db.todos.doneAt.isNull();
    }

    if (query.energyLevels.isNotEmpty) {
      where = where & _effectiveEnergyLevel.isIn(query.energyLevels.toList());
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
          (_effectiveTimeEstimate.isNull() |
              _effectiveTimeEstimate
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

    return q.watch();
  }

  /// Returns a reactive count of completed tasks that match [query] (ignoring
  /// [query.includeDone]). Used to populate the "N matches in completed tasks"
  /// hint when the primary results stream is empty.
  Stream<int> countDoneOnlyMatches(SearchQuery query) {
    if (query.text.isEmpty || query.includeDone) return Stream.value(0);

    final doneQuery = query.copyWith(includeDone: true);

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

    Expression<bool> where = _db.todos.doneAt.isNotNull();

    if (query.energyLevels.isNotEmpty) {
      where = where & _effectiveEnergyLevel.isIn(query.energyLevels.toList());
    }

    if (query.dueDateAfter != null) {
      where =
          where & _db.todos.dueDate.isBiggerOrEqualValue(query.dueDateAfter!);
    }
    if (query.dueDateBefore != null) {
      where = where &
          _db.todos.dueDate.isSmallerOrEqualValue(query.dueDateBefore!);
    }

    if (query.timeEstimateMaxMinutes != null) {
      where = where &
          (_effectiveTimeEstimate.isNull() |
              _effectiveTimeEstimate
                  .isSmallerOrEqualValue(query.timeEstimateMaxMinutes!));
    }

    q.where(where);

    // Count only — no hydration needed; _groupAndFilter reads the raw todo for
    // the text/tag filter, which the effective columns don't affect.
    return q.watch().map((rows) => _groupAndFilter(rows, doneQuery).length);
  }

  // ---------------------------------------------------------------------------
  // Row processing
  // ---------------------------------------------------------------------------

  /// Groups [rows] by todo id and applies the Dart-side text + tag-scope
  /// filter. Returns [_TodoWithTags] entries that pass all filters.
  List<_TodoWithTags> _groupAndFilter(
    List<TypedResult> rows,
    SearchQuery query, {
    bool hydrateEffective = false,
  }) {
    final Map<String, _TodoWithTags> grouped = {};
    final List<String> orderedIds = [];

    for (final row in rows) {
      var todo = row.readTable(_db.todos);
      // Overlay the Action-grain energy/time the outcome query selected
      // (ADR-0001 story 7). Only the outcome-results path adds these columns;
      // the done-count path does not read the hydrated Todo, so it skips this.
      if (hydrateEffective) {
        todo = todo.copyWith(
          energyLevel: Value(row.read(_effectiveEnergyLevel)),
          timeEstimate: Value(row.read(_effectiveTimeEstimate)),
        );
      }
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
    final result = <_TodoWithTags>[];

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

      // Text filter applied in Dart so the SQL query stays simple — there is no
      // FTS index to consult (see the class doc).
      if (term.isNotEmpty) {
        final titleHit = todo.title.toLowerCase().contains(term);
        final notesHit = todo.notes?.toLowerCase().contains(term) ?? false;
        final tagHit = tags.any((t) => t.name.toLowerCase().contains(term));
        if (!titleHit && !notesHit && !tagHit) continue;
      }

      result.add(entry);
    }

    return result;
  }

  List<SearchResult> _processRows(
    List<TypedResult> rows,
    SearchQuery query,
  ) {
    final entries = _groupAndFilter(rows, query, hydrateEffective: true);
    final term = query.text.toLowerCase().trim();

    return entries.map((entry) {
      final todo = entry.todo;
      final tags = entry.tags;

      Set<SearchMatchField> matchedFields;
      String? snippet;

      if (term.isNotEmpty) {
        final notesHit = todo.notes?.toLowerCase().contains(term) ?? false;
        matchedFields = _computeMatchedFields(todo, tags, term);
        snippet = notesHit ? _extractSnippet(todo.notes, term) : null;
      } else {
        matchedFields = const {};
        snippet = null;
      }

      return SearchResult(
        todo: todo,
        capture: null,
        tags: tags,
        matchedFields: matchedFields,
        matchSnippet: snippet,
      );
    }).toList();
  }

  /// Capture-side counterpart of [_processRows]. Groups the join rows by
  /// Capture id and applies the same Dart-side text + tag-scope filter, so a
  /// Capture matches on its title, its notes, or the name of a tag hint.
  List<SearchResult> _processCaptureRows(
    List<TypedResult> rows,
    SearchQuery query,
  ) {
    final grouped = <String, (Capture, List<Tag>)>{};
    final orderedIds = <String>[];

    for (final row in rows) {
      final capture = row.readTable(_db.captures);
      final tag = row.readTableOrNull(_db.tags);

      if (!grouped.containsKey(capture.id)) {
        grouped[capture.id] = (capture, <Tag>[]);
        orderedIds.add(capture.id);
      }
      if (tag != null) grouped[capture.id]!.$2.add(tag);
    }

    final term = query.text.toLowerCase().trim();
    final results = <SearchResult>[];

    for (final id in orderedIds) {
      final (capture, tags) = grouped[id]!;

      if (query.tagIds.isNotEmpty) {
        final hintIds = tags.map((t) => t.id).toSet();
        if (!query.tagIds.any(hintIds.contains)) continue;
      }

      final notesHit = capture.notes?.toLowerCase().contains(term) ?? false;
      if (term.isNotEmpty) {
        final titleHit = capture.title.toLowerCase().contains(term);
        final tagHit = tags.any((t) => t.name.toLowerCase().contains(term));
        if (!titleHit && !notesHit && !tagHit) continue;
      }

      results.add(SearchResult(
        capture: capture,
        tags: tags,
        matchedFields: term.isEmpty
            ? const {}
            : _matchedFieldsFor(
                title: capture.title,
                notes: capture.notes,
                tags: tags,
                term: term,
              ),
        matchSnippet:
            term.isNotEmpty && notesHit ? _extractSnippet(capture.notes, term) : null,
      ));
    }

    return results;
  }

  /// Emits whenever either source emits, combining the latest value of each.
  ///
  /// Hand-rolled rather than pulling in rxdart for a single call site: the two
  /// legs of [search] are independent Drift streams that must both stay live,
  /// and neither emits on a fixed schedule.
  Stream<R> _combineLatest<A, B, R>(
    Stream<A> a,
    Stream<B> b,
    R Function(A, B) combine,
  ) {
    late StreamController<R> controller;
    StreamSubscription<A>? subA;
    StreamSubscription<B>? subB;
    late A latestA;
    late B latestB;
    var hasA = false;
    var hasB = false;

    void emit() {
      if (hasA && hasB) controller.add(combine(latestA, latestB));
    }

    controller = StreamController<R>(
      onListen: () {
        subA = a.listen(
          (v) {
            latestA = v;
            hasA = true;
            emit();
          },
          onError: controller.addError,
        );
        subB = b.listen(
          (v) {
            latestB = v;
            hasB = true;
            emit();
          },
          onError: controller.addError,
        );
      },
      onCancel: () async {
        await subA?.cancel();
        await subB?.cancel();
      },
    );

    return controller.stream;
  }

  Set<SearchMatchField> _computeMatchedFields(
    Todo todo,
    List<Tag> tags,
    String term,
  ) =>
      _matchedFieldsFor(
        title: todo.title,
        notes: todo.notes,
        tags: tags,
        term: term,
      );

  Set<SearchMatchField> _matchedFieldsFor({
    required String title,
    required String? notes,
    required List<Tag> tags,
    required String term,
  }) {
    final fields = <SearchMatchField>{};

    if (title.toLowerCase().contains(term)) {
      fields.add(SearchMatchField.title);
    }
    if (notes?.toLowerCase().contains(term) ?? false) {
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
