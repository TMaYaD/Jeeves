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
  /// Validates the transition via [GtdStateMachine] before writing.
  /// Throws [InvalidStateTransitionException] for invalid moves.
  Future<void> processInboxItem(String todoId, {required String newState}) async {
    final row = await (select(todos)..where((t) => t.id.equals(todoId)))
        .getSingleOrNull();
    if (row == null) return;

    final from = GtdState.fromString(row.state);
    final to = GtdState.fromString(newState);
    GtdStateMachine.validate(from, to);

    await (update(todos)..where((t) => t.id.equals(todoId)))
        .write(TodosCompanion(state: Value(newState)));
  }
}
