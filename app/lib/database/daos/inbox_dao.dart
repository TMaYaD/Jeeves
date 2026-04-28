/// DAO for the GTD inbox — todos with clarified = false.
library;

import 'package:drift/drift.dart';

import '../gtd_database.dart';

part 'inbox_dao.g.dart';

@DriftAccessor(tables: [Todos, Tags, TodoTags])
class InboxDao extends DatabaseAccessor<GtdDatabase> with _$InboxDaoMixin {
  InboxDao(super.db);

  /// Stream of all inbox todos for [userId], ordered by createdAt descending.
  ///
  /// Inbox items are those with clarified = false.  When [tagIds] is non-empty
  /// only todos carrying **all** specified tags are returned (AND semantics).
  Stream<List<Todo>> watchInbox(String userId, {Set<String> tagIds = const {}}) {
    if (tagIds.isEmpty) {
      return (select(todos)
            ..where((t) => t.userId.equals(userId) & t.clarified.equals(false))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .watch();
    }

    final n = tagIds.length;
    final placeholders = List.filled(n, '?').join(', ');
    return customSelect(
      'SELECT todos.* FROM todos '
      'WHERE todos.user_id = ? AND todos.clarified = 0 '
      'AND (SELECT COUNT(DISTINCT tag_id) FROM todo_tags '
      '     WHERE todo_id = todos.id AND user_id = ? '
      '       AND tag_id IN ($placeholders)) = $n '
      'ORDER BY todos.created_at DESC',
      variables: [
        Variable(userId),
        Variable(userId),
        ...tagIds.map(Variable.new),
      ],
      readsFrom: {todos, todoTags},
    ).watch().map((rows) => rows.map((row) => todos.map(row.data)).toList());
  }

  /// Inserts a new inbox item (sets clarified = false).
  Future<void> insertTodo(TodosCompanion companion) {
    return into(todos).insert(
      companion.copyWith(clarified: const Value(false)),
    );
  }

  /// Deletes an inbox item scoped to [userId].
  ///
  /// Only removes rows where clarified = false so clarified items are
  /// not accidentally deleted via this path.
  Future<int> deleteTodo(String id, {required String userId}) {
    return (delete(todos)
          ..where(
            (t) =>
                t.id.equals(id) &
                t.userId.equals(userId) &
                t.clarified.equals(false),
          ))
        .go();
  }

  /// Sets clarified = true on the given inbox item, optionally updating
  /// [newState], [intent], and [dueDate].
  ///
  /// Scoped to [userId] to prevent cross-user mutations.  No FSM validation
  /// is performed — the caller is responsible for choosing a valid state.
  Future<void> processInboxItem(
    String id, {
    required String userId,
    String? newState,
    String? intent,
    DateTime? dueDate,
  }) async {
    await (update(todos)
          ..where(
            (t) =>
                t.id.equals(id) &
                t.userId.equals(userId) &
                t.clarified.equals(false),
          ))
        .write(TodosCompanion(
      clarified: const Value(true),
      state: newState != null ? Value(newState) : const Value.absent(),
      intent: intent != null ? Value(intent) : const Value.absent(),
      dueDate: dueDate != null ? Value(dueDate) : const Value.absent(),
      updatedAt: Value(DateTime.now()),
    ));
  }
}
