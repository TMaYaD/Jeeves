import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:drift/drift.dart';

import '../database/gtd_database.dart';
import '../models/todo.dart' show Intent, RoutingKind;
import 'auth_provider.dart';
import 'database_provider.dart';

/// Watches a single todo by ID, re-emitting on any change.
final taskDetailTodoProvider =
    StreamProvider.autoDispose.family<Todo?, String>((ref, todoId) {
  final db = ref.watch(databaseProvider);
  return db.todoDao.watchTodo(todoId);
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
        title: title.trim(),
      );

  Future<void> updateNotes(String notes) => _db.todoDao.updateFields(
        _todoId,
        notes: notes,
      );

  Future<void> setEnergyLevel(String level) => _db.todoDao.updateFields(
        _todoId,
        energyLevel: level,
      );

  // Route clear-cursor writes through the DAO so last_clarified_at is stamped
  // consistently with every other Action mutation (ADR-0001 + CONTEXT.md L152).
  Future<void> clearEnergyLevel() => _db.todoDao.updateFields(
        _todoId,
        clearEnergyLevel: true,
      );

  Future<void> clearTimeEstimate() => _db.todoDao.updateFields(
        _todoId,
        clearTimeEstimate: true,
      );

  Future<void> setTimeEstimate(int minutes) => _db.todoDao.updateFields(
        _todoId,
        timeEstimate: minutes,
      );

  Future<void> setDueDate(DateTime date) => _db.todoDao.updateFields(
        _todoId,
        dueDate: date,
      );

  Future<void> clearDueDate() => _db.todoDao.updateFields(
        _todoId,
        clearDueDate: true,
      );

  Future<void> assignProject(String tagId) =>
      _db.tagDao.enforceSingleProject(_todoId, _userId, tagId);

  Future<void> clearProject() async {
    final todo = await _db.todoDao.getTodo(_todoId);
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
    await _db.tagDao.assignTag(_todoId, tagId, _userId);
  }

  Future<void> removeContextTag(String tagId) async {
    await (_db.delete(_db.todoTags)
          ..where(
            (jt) => jt.todoId.equals(_todoId) & jt.tagId.equals(tagId),
          ))
        .go();
  }

  /// Assigns a person-typed tag to this todo and stamps last_clarified_at.
  Future<void> assignPersonTag(String tagId) async {
    await _db.tagDao.assignTag(_todoId, tagId, _userId);
    await _db.todoDao.stampLastClarifiedAt(_todoId);
  }

  /// Removes a person-typed tag from this todo and stamps last_clarified_at.
  Future<void> removePersonTag(String tagId) async {
    await (_db.delete(_db.todoTags)
          ..where(
            (jt) => jt.todoId.equals(_todoId) & jt.tagId.equals(tagId),
          ))
        .go();
    await _db.todoDao.stampLastClarifiedAt(_todoId);
  }

  /// Removes all person-typed tags from this todo and stamps last_clarified_at.
  Future<void> clearAllPersonTags() async {
    final personTagIds = await (_db.select(_db.tags)
          ..where((t) => t.type.equals('person')))
        .map((t) => t.id)
        .get();
    if (personTagIds.isEmpty) return;
    await (_db.delete(_db.todoTags)
          ..where(
            (jt) =>
                jt.todoId.equals(_todoId) & jt.tagId.isIn(personTagIds),
          ))
        .go();
    await _db.todoDao.stampLastClarifiedAt(_todoId);
  }

  Future<void> markDone() => _db.todoDao.markDone(_todoId);

  Future<void> setIntent(Intent intent) =>
      _db.todoDao.setIntent(_todoId, intent);

  /// Restores a done or trashed Outcome to the Intent named by [to]
  /// (`nextAction` or `maybe`) via [TodoDao.applyRouting]: sets the intent,
  /// clears `done_at` (cleanup invariant), and stamps `last_clarified_at`.
  /// Person tags survive (orthogonality invariant).
  Future<void> restoreTo(RoutingKind to) =>
      _db.todoDao.applyRouting(_todoId, to: to);

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
