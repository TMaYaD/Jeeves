/// DAO for the GTD inbox — todos with clarified = false.
library;

import 'package:drift/drift.dart';

import '../gtd_database.dart';
import 'tag_dao.dart' show todoTagIdFor;

part 'inbox_dao.g.dart';

@DriftAccessor(tables: [Todos, Tags, TodoTags])
class InboxDao extends DatabaseAccessor<GtdDatabase> with _$InboxDaoMixin {
  InboxDao(super.db);

  /// Stream of all inbox todos, ordered by createdAt descending.
  ///
  /// Inbox items are those with clarified = false.  When [tagIds] is non-empty
  /// only todos carrying **all** specified tags are returned (AND semantics).
  Stream<List<Todo>> watchInbox({Set<String> tagIds = const {}}) {
    if (tagIds.isEmpty) {
      return (select(todos)
            ..where((t) => t.clarified.equals(false))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .watch();
    }

    final n = tagIds.length;
    final placeholders = List.filled(n, '?').join(', ');
    return customSelect(
      'SELECT todos.* FROM todos '
      'WHERE todos.clarified = 0 '
      'AND (SELECT COUNT(DISTINCT tag_id) FROM todo_tags '
      '     WHERE todo_id = todos.id '
      '       AND tag_id IN ($placeholders)) = $n '
      'ORDER BY todos.created_at DESC',
      variables: [
        ...tagIds.map(Variable.new),
      ],
      readsFrom: {todos, todoTags},
    ).watch().map((rows) => rows.map((row) => todos.map(row.data)).toList());
  }

  /// Returns a stream that emits true as soon as there is any todo.
  ///
  /// Watches all todos (clarified or not) so that imports also collapse the
  /// first-launch onboarding card even though imported items are clarified.
  Stream<bool> watchHasTodos() =>
      (select(todos)..limit(1)).watch().map((rows) => rows.isNotEmpty);

  /// Inserts a new inbox item (sets clarified = false).
  Future<void> insertTodo(TodosCompanion companion) {
    return into(todos).insert(
      companion.copyWith(clarified: const Value(false)),
    );
  }

  /// Deletes an inbox item.
  ///
  /// Only removes rows where clarified = false so clarified items are
  /// not accidentally deleted via this path.
  Future<int> deleteTodo(String id) {
    return (delete(todos)
          ..where(
            (t) => t.id.equals(id) & t.clarified.equals(false),
          ))
        .go();
  }

  /// Reverts a processed inbox item to the explicit prior state captured by
  /// the planning ritual when the routing was applied. Used by the Back / re-
  /// route flow to undo a prior routing before re-applying.
  ///
  /// Returns the number of affected rows (1 on success, 0 if [id] not found).
  Future<int> unprocessInboxItem(
    String id, {
    required bool priorClarified,
    required String priorIntent,
    required String? priorDoneAt,
  }) {
    return (update(todos)..where((t) => t.id.equals(id))).write(
      TodosCompanion(
        clarified: Value(priorClarified),
        intent: Value(priorIntent),
        doneAt: Value(priorDoneAt),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Sets the person-typed tag associations for [todoId] to exactly
  /// [targetPersonTagIds]: removes person tags currently assigned but not in
  /// the target set, and adds tags in the target set that are not currently
  /// assigned. Non-person tag associations on the todo are left untouched.
  ///
  /// Used by the planning ritual's revert path to restore the captured
  /// pre-routing person-tag set, instead of clearing all (which would lose
  /// pre-existing associations from import / sync).
  Future<void> setPersonTagsForTodo(
    String todoId,
    Set<String> targetPersonTagIds,
    String userId,
  ) async {
    final allPersonTagIds = await (select(tags)
          ..where((t) => t.type.equals('person')))
        .map((t) => t.id)
        .get();
    if (allPersonTagIds.isEmpty) return;

    final currentRows = await (select(todoTags)
          ..where(
            (tt) => tt.todoId.equals(todoId) & tt.tagId.isIn(allPersonTagIds),
          ))
        .get();
    final currentTagIds = currentRows.map((r) => r.tagId).toSet();

    final toRemove = currentTagIds.difference(targetPersonTagIds);
    final toAdd = targetPersonTagIds.difference(currentTagIds);

    if (toRemove.isNotEmpty) {
      await (delete(todoTags)
            ..where(
              (tt) => tt.todoId.equals(todoId) & tt.tagId.isIn(toRemove),
            ))
          .go();
    }
    for (final tagId in toAdd) {
      await into(todoTags).insert(
        TodoTagsCompanion(
          id: Value(todoTagIdFor(todoId, tagId)),
          todoId: Value(todoId),
          tagId: Value(tagId),
          userId: Value(userId),
        ),
        mode: InsertMode.insertOrReplace,
      );
    }
  }

  /// Sets clarified = true on the given inbox item, optionally updating
  /// [intent] and [dueDate].
  ///
  /// Returns the number of affected rows (0 if already clarified or not found,
  /// 1 on success). Callers can use this to guard against double-processing.
  Future<int> processInboxItem(
    String id, {
    String? intent,
    DateTime? dueDate,
  }) {
    return (update(todos)
          ..where(
            (t) => t.id.equals(id) & t.clarified.equals(false),
          ))
        .write(TodosCompanion(
      clarified: const Value(true),
      intent: intent != null ? Value(intent) : const Value.absent(),
      dueDate: dueDate != null ? Value(dueDate) : const Value.absent(),
      updatedAt: Value(DateTime.now()),
    ));
  }
}
