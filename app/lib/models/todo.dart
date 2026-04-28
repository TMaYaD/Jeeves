import 'package:freezed_annotation/freezed_annotation.dart';

import 'tag.dart';

part 'todo.freezed.dart';
part 'todo.g.dart';

/// Canonical GTD states — mirrors the backend GTD_STATES constant tuple.
enum GtdState {
  nextAction,
  waitingFor,
  inProgress,
  done;

  String get value => switch (this) {
        GtdState.nextAction => 'next_action',
        GtdState.waitingFor => 'waiting_for',
        GtdState.inProgress => 'in_progress',
        GtdState.done => 'done',
      };

  static GtdState fromString(String value) {
    // Legacy: inbox rows are treated as next_action after migration 0016.
    if (value == 'inbox') return GtdState.nextAction;
    // Legacy: blocked rows are collapsed to next_action (migration 0012).
    if (value == 'blocked') return GtdState.nextAction;
    return switch (value) {
      'next_action' => GtdState.nextAction,
      'waiting_for' => GtdState.waitingFor,
      // Legacy: scheduled rows were collapsed to next_action in migration 0011.
      'scheduled' => GtdState.nextAction,
      'in_progress' => GtdState.inProgress,
      // Legacy: someday_maybe rows became next_action + intent='maybe' in migration 0015.
      'someday_maybe' => GtdState.nextAction,
      // Legacy: deferred rows were collapsed to next_action in migration 0013.
      'deferred' => GtdState.nextAction,
      'done' => GtdState.done,
      _ => () {
          assert(false, 'Unknown GtdState value: $value');
          return GtdState.nextAction;
        }(),
    };
  }

  /// Human-readable display label.
  String get displayName => switch (this) {
        GtdState.nextAction => 'Next Actions',
        GtdState.waitingFor => 'Waiting For',
        GtdState.inProgress => 'In Progress',
        GtdState.done => 'Done',
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
    required bool completed,
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

  /// True when the todo is actionable (state is next_action).
  bool get isActionable => state == GtdState.nextAction.value;

  /// Convenience accessor for the typed GTD state.
  GtdState get gtdState => GtdState.fromString(state);

  /// Project tag, if any. There may be at most one.
  Tag? get projectTag => tags.where((t) => t.isProject).firstOrNull;

  /// Area tag, if any.
  Tag? get areaTag => tags.where((t) => t.isArea).firstOrNull;

  /// Context tags.
  List<Tag> get contextTags => tags.where((t) => t.isContext).toList();
}
