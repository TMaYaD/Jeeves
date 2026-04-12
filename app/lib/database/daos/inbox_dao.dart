/// DAO for the GTD inbox — todos with state = 'inbox'.
library;

import 'package:drift/drift.dart';

import '../gtd_database.dart';

part 'inbox_dao.g.dart';

@DriftAccessor(tables: [Todos, Tags, TodoTags])
class InboxDao extends DatabaseAccessor<GtdDatabase> with _$InboxDaoMixin {
  InboxDao(super.db);

  /// Stream of all inbox todos for [userId], ordered by createdAt descending.
  Stream<List<Todo>> watchInbox(String userId) {
    return (select(todos)
          ..where((t) => t.userId.equals(userId) & t.state.equals('inbox'))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .watch();
  }

  /// Transition a todo out of inbox to [newState].
  Future<void> processInboxItem(String todoId, {required String newState}) {
    return (update(todos)..where((t) => t.id.equals(todoId)))
        .write(TodosCompanion(state: Value(newState)));
  }
}
