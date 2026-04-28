import 'package:freezed_annotation/freezed_annotation.dart';

import 'tag.dart';

part 'todo.freezed.dart';
part 'todo.g.dart';

/// Orthogonal intent enum — independent of GTD state.
///
/// next: normal actionable item; maybe: deferred for later consideration;
/// trash: marked for deletion (UX deferred to a future PR).
enum Intent {
  next,
  maybe,
  trash;

  String get value => switch (this) {
        Intent.next => 'next',
        Intent.maybe => 'maybe',
        Intent.trash => 'trash',
      };

  static Intent fromString(String value) => switch (value) {
        'maybe' => Intent.maybe,
        'trash' => Intent.trash,
        _ => Intent.next,
      };
}

@freezed
abstract class Todo with _$Todo {
  const Todo._();

  const factory Todo({
    required String id,
    required String title,
    String? notes,

    /// ISO-8601 UTC timestamp; non-null when the task has been completed.
    String? doneAt,

    required DateTime createdAt,
    DateTime? updatedAt,
    DateTime? dueDate,
    String? locationId,
    @Default([]) List<String> reminderIds,
    @Default([]) List<Tag> tags,
    int? priority,

    /// Orthogonal intent: next | maybe | trash (migration 0015).
    @Default('next') String intent,

    /// Whether this todo has been processed through the inbox clarification step.
    /// false = still in inbox; true = clarified and assigned to a GTD list.
    @Default(true) bool clarified,

    /// Estimated effort in minutes.
    int? timeEstimate,

    /// Required energy level: low | medium | high.
    String? energyLevel,

    /// How this todo entered the inbox: manual | share_sheet | voice | ai_parse.
    String? captureSource,
  }) = _Todo;

  factory Todo.fromJson(Map<String, dynamic> json) => _$TodoFromJson(json);

  /// True when the task has been marked done.
  bool get isDone => doneAt != null;

  /// True when the todo is actionable (not yet done).
  bool get isActionable => doneAt == null;

  /// Project tag, if any. There may be at most one.
  Tag? get projectTag => tags.where((t) => t.isProject).firstOrNull;

  /// Area tag, if any.
  Tag? get areaTag => tags.where((t) => t.isArea).firstOrNull;

  /// Context tags.
  List<Tag> get contextTags => tags.where((t) => t.isContext).toList();
}
