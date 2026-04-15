import 'package:freezed_annotation/freezed_annotation.dart';

import 'tag.dart';

part 'todo.freezed.dart';
part 'todo.g.dart';

/// Canonical GTD states — mirrors the backend GTD_STATES constant tuple.
enum GtdState {
  inbox,
  nextAction,
  waitingFor,
  scheduled,
  inProgress,
  somedayMaybe,
  deferred,
  done;

  String get value => switch (this) {
        GtdState.inbox => 'inbox',
        GtdState.nextAction => 'next_action',
        GtdState.waitingFor => 'waiting_for',
        GtdState.scheduled => 'scheduled',
        GtdState.inProgress => 'in_progress',
        GtdState.somedayMaybe => 'someday_maybe',
        GtdState.deferred => 'deferred',
        GtdState.done => 'done',
      };

  static GtdState fromString(String value) => switch (value) {
        'inbox' => GtdState.inbox,
        'next_action' => GtdState.nextAction,
        'waiting_for' => GtdState.waitingFor,
        'scheduled' => GtdState.scheduled,
        'in_progress' => GtdState.inProgress,
        'someday_maybe' => GtdState.somedayMaybe,
        'deferred' => GtdState.deferred,
        'done' => GtdState.done,
        _ => GtdState.inbox,
      };

  /// Human-readable display label.
  String get displayName => switch (this) {
        GtdState.inbox => 'Inbox',
        GtdState.nextAction => 'Next Actions',
        GtdState.waitingFor => 'Waiting For',
        GtdState.scheduled => 'Scheduled',
        GtdState.inProgress => 'In Progress',
        GtdState.somedayMaybe => 'Someday / Maybe',
        GtdState.deferred => 'Deferred',
        GtdState.done => 'Done',
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
    @Default('inbox') String state,

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
