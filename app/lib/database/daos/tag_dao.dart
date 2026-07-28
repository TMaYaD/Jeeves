/// DAO for typed tags (context / project / area / label) and their todo associations.
library;

import 'package:drift/drift.dart';
import 'package:powersync/powersync.dart' show uuid;
import 'package:uuid/enums.dart' show Namespace;

import '../../sync/collection_codecs.dart';
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

  /// Stream of all tags of [type], ordered by name.
  Stream<List<Tag>> watchByType(String type) {
    return (select(tags)
          ..where((t) => t.type.equals(type))
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .watch();
  }

  /// Stream of all person-typed tags, ordered by name.
  Stream<List<Tag>> watchPersonTags() => watchByType('person');

  /// Return an existing tag's id for the `(name, type)` pair, or create one.
  ///
  /// All tag-creation paths must funnel through here so duplicate `(name, type)`
  /// rows never land in `tags`. `findPersonTagByName` (and its callers) assume
  /// at most one row per `(name, 'person')`; multiple rows would crash that
  /// query with `Bad state: Too many elements`.
  ///
  /// Assigns a derived color automatically when creating. Under the
  /// single-user-per-local-DB invariant [userId] matches any pre-existing row's
  /// user_id; when it doesn't, the existing row is reused unchanged.
  ///
  /// Runs inside a transaction so the SELECT and INSERT are serialised against
  /// the database connection — without this, two concurrent calls awaiting the
  /// SELECT could interleave and each mint a fresh row for the same
  /// `(name, type)`. The SELECT is `limit(1)` so legacy duplicates that may
  /// still be on disk before the startup `dedupeTags` pass completes do not
  /// crash `getSingleOrNull`.
  Future<String> findOrCreateTag(String name, String type, String userId) {
    final trimmed = name.trim();
    return attachedDatabase.capturing(() => transaction(() async {
      final existing = await (select(tags)
            ..where((t) => t.name.equals(trimmed) & t.type.equals(type))
            ..orderBy([(t) => OrderingTerm.asc(t.id)])
            ..limit(1))
          .getSingleOrNull();
      if (existing != null) return existing.id;
      final id = uuid.v4();
      final colorHex = tagColorToHex(tagColorForName(trimmed));
      await upsertTag(TagsCompanion(
        id: Value(id),
        name: Value(trimmed),
        type: Value(type),
        color: Value(colorHex),
        userId: Value(userId),
      ));
      return id;
    }));
  }

  /// Create a new person-typed tag with the given [name] for [userId].
  ///
  /// Thin wrapper over [findOrCreateTag] preserved for readability at call sites.
  Future<String> createPersonTag(String name, String userId) =>
      findOrCreateTag(name, 'person', userId);

  /// Look up an existing person-typed tag by [name].
  ///
  /// Uses `orderBy(id).limit(1)` so legacy `(name, 'person')` duplicates that
  /// may still be on disk before [dedupeTags] completes do not crash
  /// `getSingleOrNull` with `Bad state: Too many elements`. The result is
  /// deterministic across calls — matching the canonicalisation rule used by
  /// [findOrCreateTag] and [dedupeTags] (MIN(id) as the stable choice).
  Future<Tag?> findPersonTagByName(String name) {
    return (select(tags)
          ..where((t) => t.name.equals(name) & t.type.equals('person'))
          ..orderBy([(t) => OrderingTerm.asc(t.id)])
          ..limit(1))
        .getSingleOrNull();
  }

  /// Stream of tags of [type] paired with their active-task count.
  ///
  /// "Active" means clarified=1 (not in inbox) and done_at IS NULL.  Tags
  /// with zero active tasks return count = 0 and are still included so the
  /// cloud can show them as demoted/faded rather than vanishing mid-session.
  Stream<List<TagWithCount>> watchTagsWithActiveCount(String type) {
    return customSelect(
      'SELECT tags.id, tags.name, tags.color, tags.type, tags.user_id, '
      'COUNT(t.id) AS active_count '
      'FROM tags '
      'LEFT JOIN todo_tags tt ON tt.tag_id = tags.id '
      'LEFT JOIN todos t ON t.id = tt.todo_id AND t.done_at IS NULL AND t.clarified = 1 '
      'WHERE tags.type = ? '
      'GROUP BY tags.id '
      'ORDER BY tags.name',
      variables: [
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
    return attachedDatabase.capturing(() => transaction(() async {
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
          // Only the fields the caller actually set: re-asserting the whole row
          // on a colour change would carry a stale `name` under a fresh clock
          // and clobber a concurrent rename from another device.
          _captureTag(tag.id.value, {
            if (tag.name.present) 'name': tag.name.value,
            if (tag.color.present) 'color': tag.color.value,
            if (tag.type.present) 'type': tag.type.value,
            if (tag.userId.present) 'user_id': tag.userId.value,
          });
          return;
        }
      }
      await into(tags).insert(tag, mode: InsertMode.insertOrReplace);
      if (tag.id.present) {
        // Creation asserts the full field set, so a peer that has never seen
        // the entity can build the whole row.
        final created = await (select(tags)
              ..where((t) => t.id.equals(tag.id.value)))
            .getSingleOrNull();
        if (created != null) {
          _captureTag(created.id, {
            'name': created.name,
            'color': created.color,
            'type': created.type,
            'user_id': created.userId,
          });
        }
      }
    }));
  }

  void _captureTag(String tagId, Map<String, Object?> fields) {
    if (fields.isEmpty) return;
    attachedDatabase.opCapture.write(
      collection: tagsCollection,
      entityId: tagId,
      fields: fields,
    );
  }

  void _captureTodoTag(String todoId, String tagId, String userId) {
    attachedDatabase.opCapture.write(
      collection: todoTagsCollection,
      entityId: todoTagIdFor(todoId, tagId),
      fields: {'todo_id': todoId, 'tag_id': tagId, 'user_id': userId},
    );
  }

  /// Unassignment is a tombstone op, never row absence — that is what stops a
  /// replayed or reordered assignment from silently re-attaching the tag.
  void _tombstoneTodoTag(String todoId, String tagId) {
    attachedDatabase.opCapture.tombstone(
      collection: todoTagsCollection,
      entityId: todoTagIdFor(todoId, tagId),
    );
  }

  /// Rename a tag in-place, preserving all other fields.
  ///
  /// If another tag already owns the target `(name, type)` pair, this folds
  /// the source into it via [merge] instead of writing a colliding row — an
  /// id-addressed rename to an occupied name would otherwise recreate exactly
  /// the duplicate state [findOrCreateTag] and [dedupeTags] exist to prevent.
  /// Silently returns when [tagId] is unknown or the name is unchanged.
  Future<void> rename(String tagId, String newName) {
    final trimmed = newName.trim();
    return attachedDatabase.capturing(() => transaction(() async {
      final current = await (select(tags)..where((t) => t.id.equals(tagId)))
          .getSingleOrNull();
      if (current == null) return;
      if (current.name == trimmed) return;

      final conflict = await (select(tags)
            ..where((t) =>
                t.name.equals(trimmed) &
                t.type.equals(current.type) &
                t.id.equals(tagId).not())
            ..orderBy([(t) => OrderingTerm.asc(t.id)])
            ..limit(1))
          .getSingleOrNull();
      if (conflict != null) {
        await merge(tagId, conflict.id);
        return;
      }

      await upsertTag(TagsCompanion(id: Value(tagId), name: Value(trimmed)));
    }));
  }

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
    return attachedDatabase.capturing(() => transaction(() async {
      final nullColorTags =
          await (select(tags)..where((t) => t.color.isNull())).get();
      for (final tag in nullColorTags) {
        final colorHex = tagColorToHex(tagColorForName(tag.name));
        await upsertTag(TagsCompanion(id: Value(tag.id), color: Value(colorHex)));
      }
    }));
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
    return attachedDatabase.capturing(() => transaction(() async {
      final sourceTodoTags = await (select(todoTags)
            ..where((tt) => tt.tagId.equals(sourceTagId)))
          .get();
      for (final tt in sourceTodoTags) {
        await assignTag(tt.todoId, targetTagId, tt.userId);
      }
      await (delete(todoTags)
            ..where((tt) => tt.tagId.equals(sourceTagId)))
          .go();
      // Cascade set, enumerated at capture time: the log has no FK cascade, so
      // every junction the source tag held is tombstoned explicitly alongside
      // the tag itself.
      for (final tt in sourceTodoTags) {
        _tombstoneTodoTag(tt.todoId, sourceTagId);
      }
      await (delete(tags)..where((t) => t.id.equals(sourceTagId))).go();
      attachedDatabase.opCapture
          .tombstone(collection: tagsCollection, entityId: sourceTagId);
    }));
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
    return attachedDatabase.capturing(() async {
      await into(todoTags).insert(
        TodoTagsCompanion(
          id: Value(todoTagIdFor(todoId, tagId)),
          todoId: Value(todoId),
          tagId: Value(tagId),
          userId: Value(userId),
        ),
        mode: InsertMode.insertOrReplace,
      );
      _captureTodoTag(todoId, tagId, userId);
    });
  }

  /// Returns the set of person-typed tag IDs currently assigned to [todoId].
  Future<Set<String>> getPersonTagIdsForTodo(String todoId) async {
    final rows = await customSelect(
      'SELECT tt.tag_id FROM todo_tags tt '
      'JOIN tags tg ON tg.id = tt.tag_id AND tg.type = ? '
      'WHERE tt.todo_id = ?',
      variables: [Variable('person'), Variable(todoId)],
      readsFrom: {todoTags, tags},
    ).get();
    return {for (final r in rows) r.read<String>('tag_id')};
  }

  /// Collapse duplicate `(name, type)` tag rows into a single canonical row.
  ///
  /// Operates on the `tags` view so PowerSync's `INSTEAD OF` triggers fire and
  /// the deletes/updates flow into the upload queue, reaching the backend
  /// instead of leaving cloud duplicates that resync on next startup.
  ///
  /// Canonicalisation rule for each `(name, type)` group with > 1 row:
  /// the row with the most `todo_tags` references wins, with `MIN(id)` as the
  /// deterministic tiebreaker. References on losing rows are repointed to the
  /// canonical id; colliding junction rows collapse under the
  /// `(todo_id, tag_id)` PK via `INSERT OR REPLACE` plus an explicit delete of
  /// the old junction id.
  ///
  /// Idempotent: a no-op when there are no duplicates, so it is safe to run on
  /// every startup without a version gate.
  Future<void> dedupeTags() {
    return attachedDatabase.capturing(() => transaction(() async {
      final groups = await customSelect(
        'SELECT name, type FROM tags GROUP BY name, type HAVING COUNT(*) > 1',
        readsFrom: {tags},
      ).get();
      if (groups.isEmpty) return;

      for (final group in groups) {
        final name = group.read<String>('name');
        final type = group.read<String>('type');

        final candidates = await customSelect(
          'SELECT t.id AS id, '
          '(SELECT COUNT(*) FROM todo_tags WHERE tag_id = t.id) AS ref_count '
          'FROM tags t WHERE t.name = ? AND t.type = ? '
          'ORDER BY ref_count DESC, t.id ASC',
          variables: [Variable(name), Variable(type)],
          readsFrom: {tags, todoTags},
        ).get();
        if (candidates.length < 2) continue;

        final keepId = candidates.first.read<String>('id');
        final dupIds = candidates
            .skip(1)
            .map((r) => r.read<String>('id'))
            .toList();

        for (final dupId in dupIds) {
          final junctionRows = await (select(todoTags)
                ..where((tt) => tt.tagId.equals(dupId)))
              .get();
          for (final row in junctionRows) {
            final newJunctionId = todoTagIdFor(row.todoId, keepId);
            await into(todoTags).insert(
              TodoTagsCompanion(
                id: Value(newJunctionId),
                todoId: Value(row.todoId),
                tagId: Value(keepId),
                userId: Value(row.userId),
              ),
              mode: InsertMode.insertOrReplace,
            );
            _captureTodoTag(row.todoId, keepId, row.userId);
            if (row.id != newJunctionId) {
              await (delete(todoTags)..where((tt) => tt.id.equals(row.id))).go();
            }
            _tombstoneTodoTag(row.todoId, dupId);
          }
          await (delete(tags)..where((t) => t.id.equals(dupId))).go();
          attachedDatabase.opCapture
              .tombstone(collection: tagsCollection, entityId: dupId);
        }
      }
    }));
  }

  /// Remove any existing project tag from [todoId], then assign [newProjectTagId].
  ///
  /// Enforces the single-project-per-todo invariant on the client side.
  /// Silently returns without changes if [todoId] does not exist.
  Future<void> enforceSingleProject(
      String todoId, String userId, String newProjectTagId) async {
    await attachedDatabase.capturing(() async {
      // Verify the todo exists before mutating
      final todo = await (select(todos)..where((t) => t.id.equals(todoId)))
          .getSingleOrNull();
      if (todo == null) return;

      // Find IDs of all project-typed tags
      final projectTagIds =
          await (select(tags)..where((t) => t.type.equals('project')))
              .map((t) => t.id)
              .get();

      if (projectTagIds.isNotEmpty) {
        final displaced = await (select(todoTags)
              ..where(
                (jt) => jt.todoId.equals(todoId) & jt.tagId.isIn(projectTagIds),
              ))
            .get();
        // Remove existing project associations for this todo
        await (delete(todoTags)
              ..where(
                (jt) => jt.todoId.equals(todoId) & jt.tagId.isIn(projectTagIds),
              ))
            .go();
        for (final row in displaced) {
          if (row.tagId == newProjectTagId) continue;
          _tombstoneTodoTag(todoId, row.tagId);
        }
      }

      await assignTag(todoId, newProjectTagId, userId);
    });
  }
}
