/// DAO for the GTD inbox — todos with clarified = false.
library;

import 'package:drift/drift.dart';

import '../gtd_database.dart';

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

  /// Sets clarified = true on the given inbox item, optionally updating
  /// [intent] and [dueDate].
  ///
  /// Stamps [last_clarified_at]: promoting a Capture (clarified=false) to a
  /// clarified Outcome IS Outcome creation per ADR-0006, and Outcome creation
  /// is a clarifying micro-act per CONTEXT.md.
  ///
  /// Returns the number of affected rows (0 if already clarified or not found,
  /// 1 on success). Callers can use this to guard against double-processing.
  Future<int> processInboxItem(
    String id, {
    String? intent,
    DateTime? dueDate,
  }) {
    final ts = DateTime.now();
    return (update(todos)
          ..where(
            (t) => t.id.equals(id) & t.clarified.equals(false),
          ))
        .write(TodosCompanion(
      clarified: const Value(true),
      intent: intent != null ? Value(intent) : const Value.absent(),
      dueDate: dueDate != null ? Value(dueDate) : const Value.absent(),
      lastClarifiedAt: Value(ts.toUtc()),
      updatedAt: Value(ts),
    ));
  }
}
