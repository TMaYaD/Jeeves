import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:drift/drift.dart';

import '../database/gtd_database.dart';
import '../models/gtd_state_machine.dart';
import '../models/todo.dart' show GtdState;
import 'database_provider.dart';
import 'user_constants.dart' show kLocalUserId;

/// Watches a single todo by ID, re-emitting on any change.
final taskDetailTodoProvider =
    StreamProvider.autoDispose.family<Todo?, String>((ref, todoId) {
  final db = ref.watch(databaseProvider);
  return db.todoDao.watchTodo(todoId, kLocalUserId);
});

/// Watches the Drift Tag rows associated with [todoId].
final taskTagsProvider =
    StreamProvider.autoDispose.family<List<Tag>, String>((ref, todoId) {
  final db = ref.watch(databaseProvider);
  final query = db.select(db.tags).join([
    innerJoin(db.todoTags, db.todoTags.tagId.equalsExp(db.tags.id)),
  ])
    ..where(db.todoTags.todoId.equals(todoId));
  return query.map((row) => row.readTable(db.tags)).watch();
});

/// Watches potential blocker todos for [todoId] (next_action or blocked todos, excluding self).
final taskBlockersProvider =
    StreamProvider.autoDispose.family<List<Todo>, String>((ref, todoId) {
  final db = ref.watch(databaseProvider);
  return db.todoDao.watchTodo(todoId, kLocalUserId).asyncExpand((current) {
    if (current == null) return const Stream.empty();
    return db.todoDao.watchNextActionsAndBlocked(kLocalUserId).map((items) => items.where((t) => t.id != todoId).toList());
  });
});

/// Provides mutation operations for the task detail screen.
final taskDetailNotifierProvider =
    Provider.autoDispose.family<TaskDetailNotifier, String>((ref, todoId) {
  return TaskDetailNotifier(ref, todoId);
});

class TaskDetailNotifier {
  TaskDetailNotifier(this._ref, this._todoId);

  final Ref _ref;
  final String _todoId;

  GtdDatabase get _db => _ref.read(databaseProvider);

  Future<void> updateTitle(String title) => _db.todoDao.updateFields(
        _todoId,
        kLocalUserId,
        title: title.trim(),
      );

  Future<void> updateNotes(String notes) => _db.todoDao.updateFields(
        _todoId,
        kLocalUserId,
        notes: notes,
      );

  Future<void> setEnergyLevel(String level) => _db.todoDao.updateFields(
        _todoId,
        kLocalUserId,
        energyLevel: level,
      );

  Future<void> clearEnergyLevel() async {
    await (_db.update(_db.todos)
          ..where(
              (t) => t.id.equals(_todoId) & t.userId.equals(kLocalUserId)))
        .write(TodosCompanion(
          energyLevel: const Value(null),
          updatedAt: Value(DateTime.now()),
        ));
  }

  Future<void> clearTimeEstimate() async {
    await (_db.update(_db.todos)
          ..where(
              (t) => t.id.equals(_todoId) & t.userId.equals(kLocalUserId)))
        .write(TodosCompanion(
          timeEstimate: const Value(null),
          updatedAt: Value(DateTime.now()),
        ));
  }

  Future<void> setTimeEstimate(int minutes) => _db.todoDao.updateFields(
        _todoId,
        kLocalUserId,
        timeEstimate: minutes,
      );

  Future<void> setDueDate(DateTime date) => _db.todoDao.updateFields(
        _todoId,
        kLocalUserId,
        dueDate: date,
      );

  Future<void> clearDueDate() => _db.todoDao.updateFields(
        _todoId,
        kLocalUserId,
        clearDueDate: true,
      );

  Future<void> assignProject(String tagId) =>
      _db.tagDao.enforceSingleProject(_todoId, tagId);

  Future<void> clearProject() async {
    final projectTagIds = await (_db.select(_db.tags)
          ..where((t) => t.type.equals('project')))
        .map((t) => t.id)
        .get();
    if (projectTagIds.isEmpty) return;
    await (_db.delete(_db.todoTags)
          ..where(
            (jt) =>
                jt.todoId.equals(_todoId) & jt.tagId.isIn(projectTagIds),
          ))
        .go();
  }

  Future<void> assignContextTag(String tagId) =>
      _db.tagDao.assignTag(_todoId, tagId);

  Future<void> removeContextTag(String tagId) async {
    await (_db.delete(_db.todoTags)
          ..where(
            (jt) => jt.todoId.equals(_todoId) & jt.tagId.equals(tagId),
          ))
        .go();
  }

  Future<void> setBlockedBy(String? blockingTodoId) async {
    if (blockingTodoId == null) {
      await _db.todoDao.updateFields(_todoId, kLocalUserId, clearBlockedBy: true);
    } else {
      await _db.todoDao
          .updateFields(_todoId, kLocalUserId, blockedByTodoId: blockingTodoId);
    }
  }

  /// Returns the GTD states that are valid next states from [currentState].
  List<GtdState> validNextStates(GtdState currentState) {
    return (GtdStateMachine.allowedTransitions[currentState] ?? {}).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
  }

  /// Transitions the task to [newState].
  ///
  /// When transitioning out of [GtdState.inProgress] the caller can read
  /// the updated [timeSpentMinutes] from [taskDetailTodoProvider] afterwards.
  Future<void> transition(GtdState newState, {DateTime? now}) =>
      _db.todoDao.transitionState(_todoId, kLocalUserId, newState, now: now);

  /// Watch all next-action todos for this user (excluding this task itself),
  /// as candidates for the blocked-by picker.
  Stream<List<Todo>> watchPotentialBlockers() {
    return _db.todoDao.watchTodo(_todoId, kLocalUserId).asyncExpand((current) {
      if (current == null) return const Stream.empty();
      return _db.todoDao
          .watchNextActionsAndBlocked(kLocalUserId)
          .map((items) => items.where((t) => t.id != _todoId).toList());
    });
  }

  /// Watch all tag associations for this todo (returns Drift [Tag] rows).
  Stream<List<Tag>> watchTags() {
    final query = _db.select(_db.tags).join([
      innerJoin(_db.todoTags, _db.todoTags.tagId.equalsExp(_db.tags.id)),
    ])
      ..where(_db.todoTags.todoId.equals(_todoId));
    return query.map((row) => row.readTable(_db.tags)).watch();
  }
}
