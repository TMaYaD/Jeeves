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
  Future<void> assignTag(String todoId, String tagId) {
    return into(todoTags).insertOnConflictUpdate(
      TodoTagsCompanion(todoId: Value(todoId), tagId: Value(tagId)),
    );
  }

  /// Remove any existing project tag from [todoId], then assign [newProjectTagId].
  ///
  /// Enforces the single-project-per-todo invariant on the client side.
  Future<void> enforceSingleProject(String todoId, String newProjectTagId) async {
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

    await assignTag(todoId, newProjectTagId);
  }
}
