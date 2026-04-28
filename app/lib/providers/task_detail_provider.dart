import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:drift/drift.dart';

import '../database/gtd_database.dart';
import 'auth_provider.dart';
import 'database_provider.dart';

/// Watches a single todo by ID, re-emitting on any change.
final taskDetailTodoProvider =
    StreamProvider.autoDispose.family<Todo?, String>((ref, todoId) {
  final db = ref.watch(databaseProvider);
  final userId = ref.watch(currentUserIdProvider);
  return db.todoDao.watchTodo(todoId, userId);
});

/// Watches the Drift Tag rows associated with [todoId], scoped to the current user.
final taskTagsProvider =
    StreamProvider.autoDispose.family<List<Tag>, String>((ref, todoId) {
  final db = ref.watch(databaseProvider);
  final userId = ref.watch(currentUserIdProvider);
  final query = db.select(db.tags).join([
    innerJoin(db.todoTags, db.todoTags.tagId.equalsExp(db.tags.id)),
    innerJoin(db.todos, db.todos.id.equalsExp(db.todoTags.todoId)),
  ])
    ..where(db.todoTags.todoId.equals(todoId) &
        db.todos.userId.equals(userId));
  return query.map((row) => row.readTable(db.tags)).watch();
});

/// Provides mutation operations for the task detail screen.
///
/// The notifier captures the [GtdDatabase] and current user id eagerly
/// rather than holding a [Ref].  `Provider.autoDispose` tears the ref
/// down between synchronous calls, so reading `databaseProvider` through
/// a stored [Ref] after an `await` throws "Cannot use the Ref … after it
/// has been disposed".  `GtdDatabase` is a process-wide singleton and
/// the screen pops on logout, so capturing both values at construction
/// is safe.
final taskDetailNotifierProvider =
    Provider.autoDispose.family<TaskDetailNotifier, String>((ref, todoId) {
  return TaskDetailNotifier(
    db: ref.read(databaseProvider),
    userId: ref.read(currentUserIdProvider),
    todoId: todoId,
  );
});

class TaskDetailNotifier {
  TaskDetailNotifier({
    required GtdDatabase db,
    required String userId,
    required String todoId,
  })  : _db = db,
        _userId = userId,
        _todoId = todoId;

  final GtdDatabase _db;
  final String _userId;
  final String _todoId;

  Future<void> updateTitle(String title) => _db.todoDao.updateFields(
        _todoId,
        _userId,
        title: title.trim(),
      );

  Future<void> updateNotes(String notes) => _db.todoDao.updateFields(
        _todoId,
        _userId,
        notes: notes,
      );

  Future<void> setEnergyLevel(String level) => _db.todoDao.updateFields(
        _todoId,
        _userId,
        energyLevel: level,
      );

  Future<void> clearEnergyLevel() async {
    await (_db.update(_db.todos)
          ..where(
              (t) => t.id.equals(_todoId) & t.userId.equals(_userId)))
        .write(TodosCompanion(
          energyLevel: const Value(null),
          updatedAt: Value(DateTime.now()),
        ));
  }

  Future<void> clearTimeEstimate() async {
    await (_db.update(_db.todos)
          ..where(
              (t) => t.id.equals(_todoId) & t.userId.equals(_userId)))
        .write(TodosCompanion(
          timeEstimate: const Value(null),
          updatedAt: Value(DateTime.now()),
        ));
  }

  Future<void> setTimeEstimate(int minutes) => _db.todoDao.updateFields(
        _todoId,
        _userId,
        timeEstimate: minutes,
      );

  Future<void> setDueDate(DateTime date) => _db.todoDao.updateFields(
        _todoId,
        _userId,
        dueDate: date,
      );

  Future<void> clearDueDate() => _db.todoDao.updateFields(
        _todoId,
        _userId,
        clearDueDate: true,
      );

  Future<void> assignProject(String tagId) =>
      _db.tagDao.enforceSingleProject(_todoId, _userId, tagId);

  Future<void> clearProject() async {
    final todo = await _db.todoDao.getTodo(_todoId, _userId);
    if (todo == null) return;
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

  Future<void> assignContextTag(String tagId) async {
    final todo = await _db.todoDao.getTodo(_todoId, _userId);
    if (todo == null) return;
    await _db.tagDao.assignTag(_todoId, tagId, _userId);
  }

  Future<void> removeContextTag(String tagId) async {
    final todo = await _db.todoDao.getTodo(_todoId, _userId);
    if (todo == null) return;
    await (_db.delete(_db.todoTags)
          ..where(
            (jt) => jt.todoId.equals(_todoId) & jt.tagId.equals(tagId),
          ))
        .go();
  }

  /// Sets (or clears) the [waiting_for] text column.
  ///
  /// [text] == null clears the field; empty string is also treated as a clear.
  Future<void> setWaitingFor(String? text) =>
      _db.todoDao.setWaitingFor(_todoId, _userId, text);

  /// Watch all tag associations for this todo (returns Drift [Tag] rows),
  /// scoped to the current user.
  Stream<List<Tag>> watchTags() {
    final query = _db.select(_db.tags).join([
      innerJoin(_db.todoTags, _db.todoTags.tagId.equalsExp(_db.tags.id)),
      innerJoin(_db.todos, _db.todos.id.equalsExp(_db.todoTags.todoId)),
    ])
      ..where(_db.todoTags.todoId.equals(_todoId) &
          _db.todos.userId.equals(_userId));
    return query.map((row) => row.readTable(_db.tags)).watch();
  }
}
