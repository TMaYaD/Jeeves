import 'package:freezed_annotation/freezed_annotation.dart';

import 'tag.dart';

part 'todo.freezed.dart';
part 'todo.g.dart';

/// Canonical GTD states — mirrors the backend GTD_STATES constant tuple.
enum GtdState {
  nextAction;

  String get value => switch (this) {
        GtdState.nextAction => 'next_action',
      };

  static GtdState fromString(String value) {
    // Legacy: inbox rows are treated as next_action after migration 0016.
    if (value == 'inbox') return GtdState.nextAction;
    // Legacy: blocked rows are collapsed to next_action (migration 0012).
    if (value == 'blocked') return GtdState.nextAction;
    // Legacy: done rows became next_action + done_at IS NOT NULL after migration 0017.
    if (value == 'done') return GtdState.nextAction;
    // Legacy: waiting_for rows collapsed to next_action after migration 0018.
    if (value == 'waiting_for') return GtdState.nextAction;
    // Legacy: in_progress retired in migration 0019; focus_sessions.current_task_id
    // is now the source of truth for which task is currently focused.
    if (value == 'in_progress') return GtdState.nextAction;
    return switch (value) {
      'next_action' => GtdState.nextAction,
      // Legacy: scheduled rows were collapsed to next_action in migration 0011.
      'scheduled' => GtdState.nextAction,
      // Legacy: someday_maybe rows became next_action + intent='maybe' in migration 0015.
      'someday_maybe' => GtdState.nextAction,
      // Legacy: deferred rows were collapsed to next_action in migration 0013.
      'deferred' => GtdState.nextAction,
      _ => () {
          assert(false, 'Unknown GtdState value: $value');
          return GtdState.nextAction;
        }(),
    };
  }

  /// Human-readable display label.
  String get displayName => switch (this) {
        GtdState.nextAction => 'Next Actions',
      };
}

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

    /// GTD workflow state.
    @Default('next_action') String state,

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

  /// True when the todo is actionable (next_action state and not yet done).
  bool get isActionable => state == GtdState.nextAction.value && doneAt == null;

  /// Convenience accessor for the typed GTD state.
  GtdState get gtdState => GtdState.fromString(state);

  /// Project tag, if any. There may be at most one.
  Tag? get projectTag => tags.where((t) => t.isProject).firstOrNull;

  /// Area tag, if any.
  Tag? get areaTag => tags.where((t) => t.isArea).firstOrNull;

  /// Context tags.
  List<Tag> get contextTags => tags.where((t) => t.isContext).toList();
}
