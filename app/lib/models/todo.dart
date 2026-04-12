import 'package:freezed_annotation/freezed_annotation.dart';

part 'todo.freezed.dart';
part 'todo.g.dart';

@freezed
abstract class Todo with _$Todo {
  const factory Todo({
    required String id,
    required String title,
    String? notes,
    required bool completed,
    required DateTime createdAt,
    DateTime? updatedAt,
    DateTime? dueDate,
    String? listId,
    String? locationId,
    @Default([]) List<String> reminderIds,
    @Default([]) List<String> tags,
    int? priority,
  }) = _Todo;

  factory Todo.fromJson(Map<String, dynamic> json) => _$TodoFromJson(json);
}
