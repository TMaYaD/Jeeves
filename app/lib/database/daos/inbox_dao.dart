/// DAO for the GTD inbox — todos with state = 'inbox'.
library;

import 'package:drift/drift.dart';

import '../../models/gtd_state_machine.dart';
import '../../models/todo.dart' show GtdState;
import '../gtd_database.dart';

part 'inbox_dao.g.dart';

@DriftAccessor(tables: [Todos, Tags, TodoTags])
class InboxDao extends DatabaseAccessor<GtdDatabase> with _$InboxDaoMixin {
  InboxDao(super.db);

  /// Stream of all inbox todos for [userId], ordered by createdAt descending.
  ///
  /// When [tagIds] is non-empty only todos carrying **all** specified tags are
  /// returned (AND semantics).
  Stream<List<Todo>> watchInbox(String userId, {Set<String> tagIds = const {}}) {
    if (tagIds.isEmpty) {
      return (select(todos)
            ..where((t) =>
                t.userId.equals(userId) & t.state.equals(GtdState.inbox.value))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .watch();
    }

    final n = tagIds.length;
    final placeholders = List.filled(n, '?').join(', ');
    return customSelect(
      'SELECT todos.* FROM todos '
      'WHERE todos.user_id = ? AND todos.state = ? '
      'AND (SELECT COUNT(DISTINCT tag_id) FROM todo_tags '
      '     WHERE todo_id = todos.id AND tag_id IN ($placeholders)) = $n '
      'ORDER BY todos.created_at DESC',
      variables: [
        Variable(userId),
        Variable(GtdState.inbox.value),
        ...tagIds.map(Variable.new),
      ],
      readsFrom: {todos, todoTags},
    ).watch().map((rows) => rows.map((row) => todos.map(row.data)).toList());
  }

  Future<void> insertTodo(TodosCompanion companion) {
    final state = companion.state.present
        ? companion.state.value
        : GtdState.inbox.value;
    if (state != GtdState.inbox.value) {
      throw ArgumentError.value(
        state,
        'state',
        'InboxDao only accepts todos with state = inbox',
      );
    }
    return into(todos).insert(
      companion.copyWith(state: Value(GtdState.inbox.value)),
    );
  }

  Future<int> deleteTodo(String id, {required String userId}) {
    return (delete(todos)
          ..where(
            (t) =>
                t.id.equals(id) &
                t.userId.equals(userId) &
                t.state.equals(GtdState.inbox.value),
          ))
        .go();
  }

  /// Transition a todo out of inbox to [newState].
  ///
  /// - Scoped to [userId] to prevent cross-user mutations.
  /// - Rejects the operation if the row is not currently in the inbox state.
  /// - Validates the transition via [GtdStateMachine] before writing.
  /// - Runs the read, validation, and write atomically inside a transaction to
  ///   prevent check-then-write races.
  /// - Throws [InvalidStateTransitionException] for invalid moves.
  Future<void> processInboxItem(
    String todoId, {
    required String userId,
    required String newState,
  }) async {
    await transaction(() async {
      final row = await (select(todos)
            ..where((t) => t.id.equals(todoId) & t.userId.equals(userId)))
          .getSingleOrNull();
      if (row == null) return;

      final from = GtdState.fromString(row.state);
      if (from != GtdState.inbox) {
        throw ArgumentError.value(
          row.state,
          'state',
          'Todo is not in inbox',
        );
      }
      final to = GtdState.fromString(newState);
      GtdStateMachine.validate(from, to);

      final updated = await (update(todos)
            ..where((t) =>
                t.id.equals(todoId) &
                t.userId.equals(userId) &
                t.state.equals(row.state)))
          .write(TodosCompanion(state: Value(newState)));
      if (updated != 1) {
        throw StateError('Todo state changed during transition; retry');
      }
    });
  }
}
