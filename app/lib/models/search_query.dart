import 'todo.dart' show GtdState;

/// Parameters for a universal search across all GTD tasks and attributes.
class SearchQuery {
  const SearchQuery({
    this.text = '',
    this.states = const {},
    this.tagIds = const {},
    this.energyLevels = const {},
    this.dueDateBefore,
    this.dueDateAfter,
    this.timeEstimateMaxMinutes,
    this.includeDone = false,
  });

  /// Free-text substring search across title, notes, and tag names.
  final String text;

  /// When non-empty, only tasks in these GTD states are returned.
  final Set<GtdState> states;

  /// When non-empty, only tasks tagged with at least one of these tag IDs.
  final Set<String> tagIds;

  /// When non-empty, only tasks whose energy level is one of these values.
  final Set<String> energyLevels;

  final DateTime? dueDateBefore;
  final DateTime? dueDateAfter;

  /// When set, only tasks with a time estimate ≤ this value (or no estimate).
  final int? timeEstimateMaxMinutes;

  /// When true, done tasks are included in results; otherwise excluded.
  final bool includeDone;

  bool get isEmpty =>
      text.trim().isEmpty &&
      states.isEmpty &&
      tagIds.isEmpty &&
      energyLevels.isEmpty &&
      dueDateBefore == null &&
      dueDateAfter == null &&
      timeEstimateMaxMinutes == null &&
      !includeDone;

  SearchQuery copyWith({
    String? text,
    Set<GtdState>? states,
    Set<String>? tagIds,
    Set<String>? energyLevels,
    DateTime? dueDateBefore,
    bool clearDueDateBefore = false,
    DateTime? dueDateAfter,
    bool clearDueDateAfter = false,
    int? timeEstimateMaxMinutes,
    bool clearTimeEstimate = false,
    bool? includeDone,
  }) =>
      SearchQuery(
        text: text ?? this.text,
        states: states ?? this.states,
        tagIds: tagIds ?? this.tagIds,
        energyLevels: energyLevels ?? this.energyLevels,
        dueDateBefore: clearDueDateBefore
            ? null
            : (dueDateBefore ?? this.dueDateBefore),
        dueDateAfter: clearDueDateAfter
            ? null
            : (dueDateAfter ?? this.dueDateAfter),
        timeEstimateMaxMinutes: clearTimeEstimate
            ? null
            : (timeEstimateMaxMinutes ?? this.timeEstimateMaxMinutes),
        includeDone: includeDone ?? this.includeDone,
      );
}
