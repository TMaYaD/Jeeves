/// DAO for GTD views: next actions, waiting for, someday/maybe, by-project,
/// by-area, and the general-purpose [transitionState] method.
library;

import 'package:drift/drift.dart';

import '../../models/gtd_state_machine.dart';
import '../../models/todo.dart' show GtdState;
import '../gtd_database.dart';

part 'todo_dao.g.dart';

@DriftAccessor(tables: [Todos, Tags, TodoTags])
class TodoDao extends DatabaseAccessor<GtdDatabase> with _$TodoDaoMixin {
  TodoDao(super.db);

  // ---------------------------------------------------------------------------
  // Single-todo helpers
  // ---------------------------------------------------------------------------

  /// Returns a single todo by [todoId] scoped to [userId], or null if not found.
  Future<Todo?> getTodo(String todoId, String userId) {
    return (select(todos)
          ..where((t) => t.id.equals(todoId) & t.userId.equals(userId)))
        .getSingleOrNull();
  }

  /// Stream that re-emits a single todo (scoped to [userId]) whenever it changes.
  Stream<Todo?> watchTodo(String todoId, String userId) {
    return (select(todos)
          ..where((t) => t.id.equals(todoId) & t.userId.equals(userId)))
        .watchSingleOrNull();
  }

  // ---------------------------------------------------------------------------
  // GTD list watchers
  // ---------------------------------------------------------------------------

  /// Stream of all [userId] todos, watched for reactive blocked-by filtering.
  Stream<List<Todo>> _watchAllForUser(String userId) {
    return (select(todos)
          ..where((t) => t.userId.equals(userId))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .watch();
  }

  /// Returns items from [allItems] that are unblocked in [byId].
  ///
  /// A todo is unblocked when [Todo.blockedByTodoId] is null OR the blocking
  /// todo no longer exists or is in the 'done' state.
  List<Todo> _filterUnblocked(List<Todo> items, Map<String, Todo> byId) {
    return items.where((t) {
      if (t.blockedByTodoId == null) return true;
      final blocker = byId[t.blockedByTodoId];
      return blocker == null || blocker.state == GtdState.done.value;
    }).toList();
  }

  /// Stream of next-action todos for [userId], excluding blocked tasks.
  Stream<List<Todo>> watchNextActions(String userId) {
    return _watchAllForUser(userId).map((all) {
      final byId = {for (final t in all) t.id: t};
      final nextActions = all.where((t) => t.state == GtdState.nextAction.value).toList();
      return _filterUnblocked(nextActions, byId);
    });
  }

  /// Stream of waiting-for todos for [userId].
  Stream<List<Todo>> watchWaitingFor(String userId) {
    return _watchAllForUser(userId).map(
      (all) => all.where((t) => t.state == GtdState.waitingFor.value).toList(),
    );
  }

  /// Stream of someday/maybe todos for [userId].
  Stream<List<Todo>> watchSomedayMaybe(String userId) {
    return _watchAllForUser(userId).map(
      (all) => all.where((t) => t.state == GtdState.somedayMaybe.value).toList(),
    );
  }

  /// Stream of todos matching an arbitrary [state] string for [userId].
  Stream<List<Todo>> watchByState(String userId, String state) {
    return (select(todos)
          ..where((t) => t.userId.equals(userId) & t.state.equals(state))
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

  // ---------------------------------------------------------------------------
  // State transitions
  // ---------------------------------------------------------------------------

  /// General-purpose state transition with time-logging side effects.
  ///
  /// - Validates [newState] via [GtdStateMachine].
  /// - When transitioning **to** [GtdState.inProgress]: sets [inProgressSince].
  /// - When transitioning **from** [GtdState.inProgress]: computes elapsed
  ///   minutes (rounded up) since [inProgressSince] and accumulates into
  ///   [timeSpentMinutes]; clears [inProgressSince].
  ///
  /// [now] is injectable for deterministic testing; defaults to [DateTime.now].
  Future<void> transitionState(
    String todoId,
    String userId,
    GtdState newState, {
    DateTime? now,
  }) async {
    await transaction(() async {
      final row = await (select(todos)
            ..where((t) => t.id.equals(todoId) & t.userId.equals(userId)))
          .getSingleOrNull();
      if (row == null) return;

      final from = GtdState.fromString(row.state);
      GtdStateMachine.validate(from, newState);

      final effectiveNow = now ?? DateTime.now();
      final companion = _buildTransitionCompanion(row, newState, effectiveNow);

      await (update(todos)
            ..where((t) => t.id.equals(todoId) & t.userId.equals(userId)))
          .write(companion);
    });
  }

  TodosCompanion _buildTransitionCompanion(
    Todo row,
    GtdState newState,
    DateTime now,
  ) {
    var timeSpent = row.timeSpentMinutes;
    String? newInProgressSince = row.inProgressSince;

    if (GtdState.fromString(row.state) == GtdState.inProgress &&
        row.inProgressSince != null) {
      // Leaving inProgress — log elapsed time (rounded up to nearest minute).
      final started = DateTime.tryParse(row.inProgressSince!);
      if (started != null) {
        final elapsed = now.difference(started);
        final minutes = (elapsed.inSeconds / 60).ceil();
        timeSpent += minutes.clamp(0, double.maxFinite.toInt());
      }
      newInProgressSince = null;
    }

    if (newState == GtdState.inProgress) {
      newInProgressSince = now.toIso8601String();
    }

    return TodosCompanion(
      state: Value(newState.value),
      timeSpentMinutes: Value(timeSpent),
      inProgressSince: Value(newInProgressSince),
      updatedAt: Value(now),
    );
  }

  /// Update mutable todo fields (title, notes, energy level, time estimate).
  Future<void> updateFields(
    String todoId,
    String userId, {
    String? title,
    String? notes,
    String? energyLevel,
    int? timeEstimate,
    String? blockedByTodoId,
    bool clearBlockedBy = false,
  }) async {
    if (!clearBlockedBy && blockedByTodoId != null) {
      if (blockedByTodoId == todoId) {
        throw ArgumentError.value(
          blockedByTodoId,
          'blockedByTodoId',
          'A todo cannot block itself',
        );
      }
      final blocker = await (select(todos)
            ..where(
                (t) => t.id.equals(blockedByTodoId) & t.userId.equals(userId)))
          .getSingleOrNull();
      if (blocker == null) {
        throw ArgumentError.value(
          blockedByTodoId,
          'blockedByTodoId',
          'Blocking todo was not found for this user',
        );
      }
    }

    final companion = TodosCompanion(
      updatedAt: Value(DateTime.now()),
      title: title != null ? Value(title) : const Value.absent(),
      notes: notes != null ? Value(notes) : const Value.absent(),
      energyLevel: energyLevel != null ? Value(energyLevel) : const Value.absent(),
      timeEstimate: timeEstimate != null ? Value(timeEstimate) : const Value.absent(),
      blockedByTodoId: clearBlockedBy
          ? const Value(null)
          : blockedByTodoId != null
              ? Value(blockedByTodoId)
              : const Value.absent(),
    );
    await (update(todos)
          ..where((t) => t.id.equals(todoId) & t.userId.equals(userId)))
        .write(companion);
  }
}
