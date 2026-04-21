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
  /// - Returns `true` if a row was updated, `false` if the optimistic lock failed
  ///   (the row changed state since we read it).
  ///
  /// Note: in production `todos` is a PowerSync view with INSTEAD OF UPDATE
  /// triggers. SQLite reports 0 changes for UPDATE statements handled by a trigger
  /// body (`sqlite3_changes()` excludes lower-level trigger writes), so the
  /// return value may be unreliable in that environment. Use this return value
  /// for detecting concurrent updates in tests or non-PowerSync environments.
  Future<bool> processInboxItem(
    String todoId, {
    required String userId,
    required String newState,
  }) async {
    return await transaction(() async {
      final row = await (select(todos)
            ..where((t) => t.id.equals(todoId) & t.userId.equals(userId)))
          .getSingleOrNull();
      if (row == null) return false;

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

      final rows = await (update(todos)
            ..where((t) =>
                t.id.equals(todoId) &
                t.userId.equals(userId) &
                t.state.equals(row.state)))
          .write(TodosCompanion(
        state: Value(newState),
        updatedAt: Value(DateTime.now()),
      ));

      return rows > 0;
    });
  }

  /// Atomically transitions an inbox item to the scheduled state.
  ///
  /// This performs the two-step transition (inbox → nextAction → scheduled)
  /// inside a single transaction, ensuring atomicity. If either step fails,
  /// the entire operation is rolled back.
  ///
  /// - First transitions the todo from inbox to nextAction state
  /// - Then transitions from nextAction to scheduled state
  /// - Scoped to [userId] to prevent cross-user mutations
  /// - Validates both transitions via [GtdStateMachine]
  /// - Returns `true` if both transitions succeeded, `false` if the todo
  ///   was not found or already processed
  ///
  /// This method should be used when scheduling an inbox item directly during
  /// the daily planning ritual to avoid race conditions from separate calls.
  Future<bool> transitionInboxToScheduled(
    String todoId, {
    required String userId,
  }) async {
    return await transaction(() async {
      // Step 1: Read and validate initial state
      final row = await (select(todos)
            ..where((t) => t.id.equals(todoId) & t.userId.equals(userId)))
          .getSingleOrNull();
      if (row == null) return false;

      final from = GtdState.fromString(row.state);
      if (from != GtdState.inbox) {
        throw ArgumentError.value(
          row.state,
          'state',
          'Todo is not in inbox',
        );
      }

      // Validate both hops in the transition
      GtdStateMachine.validate(GtdState.inbox, GtdState.nextAction);
      GtdStateMachine.validate(GtdState.nextAction, GtdState.scheduled);

      final now = DateTime.now();

      // Step 2: Transition inbox → nextAction
      final rows1 = await (update(todos)
            ..where((t) =>
                t.id.equals(todoId) &
                t.userId.equals(userId) &
                t.state.equals(row.state)))
          .write(TodosCompanion(
        state: Value(GtdState.nextAction.value),
        updatedAt: Value(now),
      ));

      if (rows1 == 0) return false;

      // Step 3: Transition nextAction → scheduled
      final rows2 = await (update(todos)
            ..where((t) =>
                t.id.equals(todoId) &
                t.userId.equals(userId) &
                t.state.equals(GtdState.nextAction.value)))
          .write(TodosCompanion(
        state: Value(GtdState.scheduled.value),
        updatedAt: Value(now),
      ));

      return rows2 > 0;
    });
  }
}