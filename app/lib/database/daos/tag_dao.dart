/// DAO for typed tags (context / project / area / label) and their todo associations.
library;

import 'package:drift/drift.dart';
import 'package:powersync/powersync.dart' show uuid;
import 'package:uuid/enums.dart' show Namespace;

import '../gtd_database.dart';

part 'tag_dao.g.dart';

/// Deterministic `todo_tags.id` for the (todoId, tagId) pair.
///
/// PowerSync's view INSERT trigger inserts `NEW.id` into the backing
/// `ps_data__todo_tags` table, so the junction row needs an explicit id.
/// Deriving it as a UUID v5 of the pair makes re-assignment of the same
/// tag produce the same id, so `INSERT OR REPLACE` collapses to a no-op
/// rather than inserting a duplicate row each time the user taps the tag.
/// The backend's `create_todo_tag` handler also dedupes by id, so replays
/// through the PowerSync upload queue stay idempotent.
String todoTagIdFor(String todoId, String tagId) =>
    uuid.v5(Namespace.url.value, 'jeeves://todo_tag/$todoId/$tagId');

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
  ///
  /// Uses INSERT OR REPLACE instead of INSERT ... ON CONFLICT DO UPDATE because
  /// todos/tags/todo_tags are PowerSync SQLite views — SQLite forbids UPSERT
  /// syntax on views even when INSTEAD OF triggers are present.
  Future<void> upsertTag(TagsCompanion tag) {
    return into(tags).insert(tag, mode: InsertMode.insertOrReplace);
  }

  /// Associate a tag with a todo (idempotent).
  ///
  /// [userId] is denormalized onto the junction row so PowerSync can sync it
  /// in a per-user bucket (see sync-config.yaml `by_user_todo_tags`).  It
  /// must match the parent todo's `user_id`; callers typically pass
  /// `ref.read(currentUserIdProvider)`.
  ///
  /// Uses INSERT OR REPLACE for the same reason as [upsertTag].  The `id`
  /// column is derived deterministically from (todoId, tagId) via
  /// [todoTagIdFor] so repeated calls collapse on the PowerSync view's
  /// backing table instead of accumulating rows.
  Future<void> assignTag(String todoId, String tagId, String userId) {
    return into(todoTags).insert(
      TodoTagsCompanion(
        id: Value(todoTagIdFor(todoId, tagId)),
        todoId: Value(todoId),
        tagId: Value(tagId),
        userId: Value(userId),
      ),
      mode: InsertMode.insertOrReplace,
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
