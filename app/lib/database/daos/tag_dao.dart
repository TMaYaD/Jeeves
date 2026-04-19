/// DAO for typed tags (context / project / area / label) and their todo associations.
library;

import 'package:drift/drift.dart';

import '../gtd_database.dart';

part 'tag_dao.g.dart';

@DriftAccessor(tables: [Tags, TodoTags, Todos])
class TagDao extends DatabaseAccessor<GtdDatabase> with _$TagDaoMixin {
  TagDao(super.db);

  /// Stream of all tags of [type] belonging to [userId].
  Stream<List<Tag>> watchByType(String userId, String type) {
    return (select(tags)
          ..where((t) => t.userId.equals(userId) & t.type.equals(type))
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .watch();
  }

  /// Insert or replace a tag row (upsert by primary key).
  Future<void> upsertTag(TagsCompanion tag) {
    return into(tags).insertOnConflictUpdate(tag);
  }

  /// Associate a tag with a todo (idempotent).
  ///
  /// [userId] is denormalized onto the junction row so PowerSync can sync it
  /// in a per-user bucket (see sync-config.yaml `by_user_todo_tags`).  It
  /// must match the parent todo's `user_id`; callers typically pass
  /// `ref.read(currentUserIdProvider)`.
  Future<void> assignTag(String todoId, String tagId, String userId) {
    return into(todoTags).insertOnConflictUpdate(
      TodoTagsCompanion(
        todoId: Value(todoId),
        tagId: Value(tagId),
        userId: Value(userId),
      ),
    );
  }

  /// Remove any existing project tag from [todoId], then assign [newProjectTagId].
  ///
  /// Enforces the single-project-per-todo invariant on the client side.
  /// Silently returns without changes if [todoId] does not belong to [userId].
  Future<void> enforceSingleProject(
      String todoId, String userId, String newProjectTagId) async {
    // Verify the todo belongs to this user before mutating
    final todo = await (select(todos)
          ..where((t) => t.id.equals(todoId) & t.userId.equals(userId)))
        .getSingleOrNull();
    if (todo == null) return;

    // Find IDs of all project-typed tags
    final projectTagIds = await (select(tags)..where((t) => t.type.equals('project')))
        .map((t) => t.id)
        .get();

    if (projectTagIds.isNotEmpty) {
      // Remove existing project associations for this todo
      await (delete(todoTags)
            ..where(
              (jt) => jt.todoId.equals(todoId) & jt.tagId.isIn(projectTagIds),
            ))
          .go();
    }

    await assignTag(todoId, newProjectTagId, userId);
  }
}
