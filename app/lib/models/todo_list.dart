import 'package:freezed_annotation/freezed_annotation.dart';

part 'todo_list.freezed.dart';
part 'todo_list.g.dart';

@freezed
abstract class TodoList with _$TodoList {
  const factory TodoList({
    required String id,
    required String name,
    String? color,
    String? iconName,
    required DateTime createdAt,
    DateTime? updatedAt,
    @Default(false) bool isArchived,
  }) = _TodoList;

  factory TodoList.fromJson(Map<String, dynamic> json) =>
      _$TodoListFromJson(json);
}
