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
  /// Conceptually this is the two-hop transition `inbox → nextAction →
  /// scheduled`. Both hops are validated via [GtdStateMachine] up front, then
  /// a single UPDATE writes the final `scheduled` state inside a transaction.
  /// Writing both hops as separate UPDATEs is not safe under PowerSync: the
  /// view's INSTEAD OF UPDATE triggers cause SQLite to report 0 affected rows,
  /// so any affected-row check between hops would spuriously early-exit.
  ///
  /// - Scoped to [userId] to prevent cross-user mutations
  /// - Validates both hops of the logical transition via [GtdStateMachine]
  /// - Pins the UPDATE with an optimistic-lock WHERE on the observed state
  /// - Returns `true` if a row was updated, `false` if the todo was not found
  ///   or the optimistic lock failed
  ///
  /// Note: in production `todos` is a PowerSync view with INSTEAD OF UPDATE
  /// triggers. SQLite reports 0 changes for UPDATE statements handled by a trigger
  /// body (`sqlite3_changes()` excludes lower-level trigger writes), so the
  /// return value may be unreliable in that environment. Use this return value
  /// for detecting concurrent updates in tests or non-PowerSync environments.
  ///
  /// This method should be used when scheduling an inbox item directly during
  /// the daily planning ritual to avoid race conditions from separate calls.
  Future<bool> transitionInboxToScheduled(
    String todoId, {
    required String userId,
  }) async {
    return await transaction(() async {
      // Read and validate initial state
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

      // Write directly to scheduled in a single UPDATE. Both hops are
      // validated above; splitting into two UPDATEs would be unsafe under
      // PowerSync (see doc comment).
      final rows = await (update(todos)
            ..where((t) =>
                t.id.equals(todoId) &
                t.userId.equals(userId) &
                t.state.equals(row.state)))
          .write(TodosCompanion(
        state: Value(GtdState.scheduled.value),
        updatedAt: Value(DateTime.now()),
      ));

      return rows > 0;
    });
  }
}