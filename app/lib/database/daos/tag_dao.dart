/// DAO for typed tags (context / project / area / label) and their todo associations.
library;

import 'package:drift/drift.dart';
import 'package:powersync/powersync.dart' show uuid;
import 'package:uuid/enums.dart' show Namespace;

import '../../utils/tag_colors.dart';
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

/// A [Tag] together with the count of active (clarified, not-done) tasks.
class TagWithCount {
  const TagWithCount({required this.tag, required this.count});

  final Tag tag;

  /// Number of active (clarified and not done) todos assigned this tag.
  final int count;
}

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

  /// Stream of tags of [type] for [userId] paired with their active-task count.
  ///
  /// "Active" means clarified=1 (not in inbox) and state is not `done`.  Tags
  /// with zero active tasks return count = 0 and are still included so the
  /// cloud can show them as demoted/faded rather than vanishing mid-session.
  Stream<List<TagWithCount>> watchTagsWithActiveCount(
      String userId, String type) {
    return customSelect(
      'SELECT tags.id, tags.name, tags.color, tags.type, tags.user_id, '
      'COUNT(t.id) AS active_count '
      'FROM tags '
      'LEFT JOIN todo_tags tt ON tt.tag_id = tags.id '
      'LEFT JOIN todos t ON t.id = tt.todo_id AND t.state != ? AND t.clarified = 1 '
      'WHERE tags.user_id = ? AND tags.type = ? '
      'GROUP BY tags.id '
      'ORDER BY tags.name',
      variables: [
        Variable('done'),
        Variable(userId),
        Variable(type),
      ],
      readsFrom: {tags, todoTags, todos},
    ).watch().map(
          (rows) => rows
              .map(
                (row) => TagWithCount(
                  tag: Tag(
                    id: row.read<String>('id'),
                    name: row.read<String>('name'),
                    color: row.readNullable<String>('color'),
                    type: row.read<String>('type'),
                    userId: row.read<String>('user_id'),
                  ),
                  count: row.read<int>('active_count'),
                ),
              )
              .toList(),
        );
  }

  /// Insert or replace a tag row (upsert by primary key).
  ///
  /// Uses INSERT OR REPLACE instead of INSERT ... ON CONFLICT DO UPDATE because
  /// todos/tags/todo_tags are PowerSync SQLite views — SQLite forbids UPSERT
  /// syntax on views even when INSTEAD OF triggers are present.
  ///
  /// When updating an existing row, any absent fields in [tag] are filled from
  /// the stored row before replacing, so partial companions never wipe columns
  /// such as [Tags.color] that the caller did not intend to change.  The
  /// SELECT and INSERT run inside a single transaction to prevent two
  /// concurrent partial updates from racing and clobbering each other.
  Future<void> upsertTag(TagsCompanion tag) {
    return transaction(() async {
      if (tag.id.present) {
        final existing = await (select(tags)
              ..where((t) => t.id.equals(tag.id.value)))
            .getSingleOrNull();
        if (existing != null) {
          await into(tags).insert(
            TagsCompanion(
              id: tag.id,
              name: tag.name.present ? tag.name : Value(existing.name),
              color: tag.color.present ? tag.color : Value(existing.color),
              type: tag.type.present ? tag.type : Value(existing.type),
              userId: tag.userId.present ? tag.userId : Value(existing.userId),
            ),
            mode: InsertMode.insertOrReplace,
          );
          return;
        }
      }
      await into(tags).insert(tag, mode: InsertMode.insertOrReplace);
    });
  }

  /// Rename a tag in-place, preserving all other fields.
  Future<void> rename(String tagId, String newName) => upsertTag(
        TagsCompanion(id: Value(tagId), name: Value(newName.trim())),
      );

  /// Update the colour of a tag; pass null to clear it.
  Future<void> updateColor(String tagId, String? color) => upsertTag(
        TagsCompanion(id: Value(tagId), color: Value(color)),
      );

  /// One-time migration: derives and persists a color for every tag whose
  /// color is currently NULL.
  ///
  /// Called from [GtdDatabase.onUpgrade] when upgrading to schema v7 — not on
  /// every startup — so intentional NULLs set via [updateColor] after the
  /// migration are never overwritten.
  Future<void> backfillAllMissingColors() {
    return transaction(() async {
      final nullColorTags =
          await (select(tags)..where((t) => t.color.isNull())).get();
      for (final tag in nullColorTags) {
        final colorHex = tagColorToHex(tagColorForName(tag.name));
        await upsertTag(TagsCompanion(id: Value(tag.id), color: Value(colorHex)));
      }
    });
  }

  /// Merge [sourceTagId] into [targetTagId].
  ///
  /// Re-assigns all `todo_tags` rows that reference [sourceTagId] to
  /// [targetTagId] (idempotent via [assignTag]), then deletes the source tag
  /// and its junction rows atomically.
  ///
  /// Throws [ArgumentError] if [sourceTagId] equals [targetTagId] — a
  /// self-merge would silently delete the tag and strip every association.
  Future<void> merge(String sourceTagId, String targetTagId) {
    if (sourceTagId == targetTagId) {
      throw ArgumentError.value(
        targetTagId,
        'targetTagId',
        'Source and target tags must differ',
      );
    }
    return transaction(() async {
      final sourceTodoTags = await (select(todoTags)
            ..where((tt) => tt.tagId.equals(sourceTagId)))
          .get();
      for (final tt in sourceTodoTags) {
        await assignTag(tt.todoId, targetTagId, tt.userId);
      }
      await (delete(todoTags)
            ..where((tt) => tt.tagId.equals(sourceTagId)))
          .go();
      await (delete(tags)..where((t) => t.id.equals(sourceTagId))).go();
    });
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
