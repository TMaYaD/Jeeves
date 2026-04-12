/// DAO for GTD views: next actions, by-project, by-area.
library;

import 'package:drift/drift.dart';

import '../gtd_database.dart';

part 'todo_dao.g.dart';

@DriftAccessor(tables: [Todos, Tags, TodoTags])
class TodoDao extends DatabaseAccessor<GtdDatabase> with _$TodoDaoMixin {
  TodoDao(super.db);

  /// Stream of next-action todos for [userId].
  Stream<List<Todo>> watchNextActions(String userId) {
    return (select(todos)
          ..where((t) => t.userId.equals(userId) & t.state.equals('next_action'))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .watch();
  }

  /// Stream of todos associated with a specific project tag [projectTagId].
  Stream<List<Todo>> watchByProject(String userId, String projectTagId) {
    final query = select(todos).join([
      innerJoin(todoTags, todoTags.todoId.equalsExp(todos.id)),
    ])
      ..where(todos.userId.equals(userId) & todoTags.tagId.equals(projectTagId));
    return query.map((row) => row.readTable(todos)).watch();
  }

  /// Stream of todos associated with a specific area tag [areaTagId].
  Stream<List<Todo>> watchByArea(String userId, String areaTagId) {
    final query = select(todos).join([
      innerJoin(todoTags, todoTags.todoId.equalsExp(todos.id)),
    ])
      ..where(todos.userId.equals(userId) & todoTags.tagId.equals(areaTagId));
    return query.map((row) => row.readTable(todos)).watch();
  }
}
