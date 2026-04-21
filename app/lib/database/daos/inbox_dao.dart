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
  Stream<List<Todo>> watchInbox(String userId) {
    return (select(todos)
          ..where((t) => t.userId.equals(userId) & t.state.equals(GtdState.inbox.value))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .watch();
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
  ///   prevent check-then-write races. The UPDATE's WHERE clause pins the
  ///   row to its observed state, acting as an optimistic lock.
  /// - Throws [InvalidStateTransitionException] for invalid moves.
  ///
  /// Note: we deliberately do NOT assert on the affected row count — in
  /// production `todos` is a PowerSync view with INSTEAD OF UPDATE triggers,
  /// and SQLite reports 0 changes for UPDATE statements handled by a trigger
  /// body (`sqlite3_changes()` excludes lower-level trigger writes).
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

      await (update(todos)
            ..where((t) =>
                t.id.equals(todoId) &
                t.userId.equals(userId) &
                t.state.equals(row.state)))
          .write(TodosCompanion(
        state: Value(newState),
        updatedAt: Value(DateTime.now()),
      ));
    });
  }
}
