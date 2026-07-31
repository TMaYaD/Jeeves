/// DAO for typed tags (context / project / area / label) and their todo associations.
library;

import 'package:drift/drift.dart';
import '../../utils/uuid.dart';
import 'package:uuid/enums.dart' show Namespace;

import '../../sync/collection_codecs.dart';
import '../../utils/tag_colors.dart';
import '../gtd_database.dart';
// `capture_tags` is the second junction that references `tags.id`, so the fold
// and the rehome pass both need its derived id. Owned by `capture_dao.dart`
// alongside the table's other write paths.
import 'capture_dao.dart' show captureTagIdFor;

part 'tag_dao.g.dart';

/// Deterministic `todo_tags.id` for the (todoId, tagId) pair.
///
/// The op log names an entity by one id, so the junction row needs an
/// explicit one. Deriving it as a UUID v5 of the pair makes re-assignment of the
/// same tag produce the same id, so `INSERT OR REPLACE` collapses to a no-op
/// rather than inserting a duplicate row each time the user taps the tag — and
/// two devices assigning the same tag offline reduce to one junction entity
/// rather than forking (`sync/ids.dart`).
String todoTagIdFor(String todoId, String tagId) =>
    uuid.v5(Namespace.url.value, 'jeeves://todo_tag/$todoId/$tagId');

/// A [Tag] together with the count of active (clarified, not-done) tasks.
class TagWithCount {
  const TagWithCount({required this.tag, required this.count});

  final Tag tag;

  /// Number of active (clarified and not done) todos assigned this tag.
  final int count;
}

@DriftAccessor(tables: [Tags, TodoTags, Todos, CaptureTags])
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
  /// **The local half of the `(name, type)` invariant.** All tag-creation paths
  /// funnel through here, so no single device can mint a duplicate pair; the
  /// cross-device half is `DomainReconciler`'s fold, because two devices doing
  /// this offline still fork into two entities (`sync/ids.dart`).
  ///
  /// Assigns a derived color automatically when creating. Under the
  /// single-user-per-local-DB invariant [userId] matches any pre-existing row's
  /// user_id; when it doesn't, the existing row is reused unchanged.
  ///
  /// Runs inside a transaction so the SELECT and INSERT are serialised against
  /// the database connection — without this, two concurrent calls awaiting the
  /// SELECT could interleave and each mint a fresh row for the same
  /// `(name, type)`. `orderBy(id).limit(1)` rather than `getSingleOrNull` on the
  /// bare predicate: a peer's duplicate is a legitimate transient state on disk,
  /// and returning `MIN(id)` is both crash-free and the same choice
  /// [foldDuplicateTags] makes, so a lookup taken before the fold runs agrees
  /// with the survivor it will pick.
  Future<String> findOrCreateTag(String name, String type, String userId) {
    final trimmed = name.trim();
    return attachedDatabase.capturing(() async {
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
    });
  }

  /// Create a new person-typed tag with the given [name] for [userId].
  ///
  /// Thin wrapper over [findOrCreateTag] preserved for readability at call sites.
  Future<String> createPersonTag(String name, String userId) =>
      findOrCreateTag(name, 'person', userId);

  /// Look up an existing person-typed tag by [name].
  ///
  /// Uses `orderBy(id).limit(1)` so a peer's `(name, 'person')` duplicate sitting
  /// on disk between arrival and the fold does not crash `getSingleOrNull` with
  /// `Bad state: Too many elements`. The result is deterministic across calls and
  /// across devices — `MIN(id)`, the same choice [findOrCreateTag] and
  /// [foldDuplicateTags] make.
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
  /// Uses INSERT OR REPLACE rather than INSERT ... ON CONFLICT DO UPDATE: the
  /// fill-from-stored-row step below is what makes a partial companion safe, and
  /// expressing it as an UPSERT would move that logic into SQL for no gain.
  ///
  /// When updating an existing row, any absent fields in [tag] are filled from
  /// the stored row before replacing, so partial companions never wipe columns
  /// such as [Tags.color] that the caller did not intend to change.  The
  /// SELECT and INSERT run inside a single transaction to prevent two
  /// concurrent partial updates from racing and clobbering each other.
  Future<void> upsertTag(TagsCompanion tag) {
    return attachedDatabase.capturing(() async {
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
    });
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

  void _captureCaptureTag(String captureId, String tagId, String userId) {
    attachedDatabase.opCapture.write(
      collection: captureTagsCollection,
      entityId: captureTagIdFor(captureId, tagId),
      fields: {
        'capture_id': captureId,
        'tag_id': tagId,
        'user_id': userId,
      },
    );
  }

  void _tombstoneCaptureTag(String captureId, String tagId) {
    attachedDatabase.opCapture.tombstone(
      collection: captureTagsCollection,
      entityId: captureTagIdFor(captureId, tagId),
    );
  }

  /// Rename a tag in-place, preserving all other fields.
  ///
  /// If another tag already owns the target `(name, type)` pair, this folds
  /// the source into it via [merge] instead of writing a colliding row: a rename
  /// onto an occupied name is the user asking for one Tag, so it merges rather
  /// than leaving a duplicate for [foldDuplicateTags] to discover later.
  /// Silently returns when [tagId] is unknown or the name is unchanged.
  Future<void> rename(String tagId, String newName) {
    final trimmed = newName.trim();
    return attachedDatabase.capturing(() async {
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
    });
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
    return attachedDatabase.capturing(() async {
      final nullColorTags =
          await (select(tags)..where((t) => t.color.isNull())).get();
      for (final tag in nullColorTags) {
        final colorHex = tagColorToHex(tagColorForName(tag.name));
        await upsertTag(TagsCompanion(id: Value(tag.id), color: Value(colorHex)));
      }
    });
  }

  /// Merge [sourceTagId] into [targetTagId] — the *user's* deliberate fold, as
  /// opposed to [foldDuplicateTags]' automatic one.
  ///
  /// Re-assigns all `todo_tags` rows that reference [sourceTagId] to
  /// [targetTagId] (idempotent via [assignTag]), then deletes the source tag
  /// and its junction rows atomically.
  ///
  /// **It repoints only `todo_tags`, so it orphans the source tag's
  /// `capture_tags` rows** — with FK enforcement off (#637) that is a silently
  /// invisible tag hint rather than an error. [repointTagReferences] is the shared
  /// helper that covers both junctions; switching this method onto it is #645.
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
    return attachedDatabase.capturing(() async {
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
    });
  }

  /// Associate a tag with a todo (idempotent).
  ///
  /// [userId] is denormalized onto the junction row so it carries its owner
  /// without a JOIN.  It
  /// must match the parent todo's `user_id`; callers typically pass
  /// `ref.read(currentUserIdProvider)`.
  ///
  /// Uses INSERT OR REPLACE for the same reason as [upsertTag].  The `id`
  /// column is derived deterministically from (todoId, tagId) via
  /// [todoTagIdFor] so repeated calls collapse onto one row instead of
  /// accumulating.
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

  /// Collapse every duplicate `(name, type)` group onto one surviving Tag.
  ///
  /// The fold pass of `DomainReconciler`. `(name, type)` is the user-facing
  /// identity of a Tag but not its op-log one: ids are client-random by protocol
  /// policy (`sync/ids.dart`), so two devices each creating "Alice"/`person`
  /// offline fork into two entities and both land in `tags` — which carries no
  /// uniqueness constraint precisely so the projection can represent them
  /// (ADR-0043).
  ///
  /// **The survivor is `MIN(id)` over the group and nothing else.** Not the most
  /// referenced row: reference counts are per-device, so two devices folding
  /// concurrently would pick different survivors, each repoint onto its own and
  /// tombstone the other's — both tombstones land, **both Tags die**, and every
  /// assignment dangles. Lexicographic `MIN(id)` over entity ids is commutative,
  /// associative and idempotent, so every device reaches the same verdict from any
  /// subset it can see.
  ///
  /// **Runs through the DAO so the decision travels as ops.** A fold that only
  /// fixed the local store would be undone by the next pull, which still carries
  /// the peer's duplicate. References on the losers are repointed by
  /// [repointTagReferences]; the loser itself is tombstoned, never merely deleted.
  ///
  /// Idempotent: with no duplicate group it authors nothing and writes nothing.
  Future<void> foldDuplicateTags() {
    return attachedDatabase.capturing(() async {
      final groups = await customSelect(
        'SELECT name, type, MIN(id) AS keep_id FROM tags '
        'GROUP BY name, type HAVING COUNT(*) > 1',
        readsFrom: {tags},
      ).get();
      if (groups.isEmpty) return;

      for (final group in groups) {
        final keepId = group.read<String>('keep_id');
        final losers = await (select(tags)
              ..where((t) =>
                  t.name.equals(group.read<String>('name')) &
                  t.type.equals(group.read<String>('type')) &
                  t.id.equals(keepId).not()))
            .get();

        for (final loser in losers) {
          await _repointTagReferences(from: loser.id, to: keepId);
          await (delete(tags)..where((t) => t.id.equals(loser.id))).go();
          // Cascade set, enumerated at capture time: the log has no FK cascade,
          // and a tombstone rather than row absence is what stops a replayed or
          // reordered create from resurrecting the loser.
          attachedDatabase.opCapture
              .tombstone(collection: tagsCollection, entityId: loser.id);
        }
      }
      attachedDatabase.notifyTagsViewWrite();
      attachedDatabase.notifyTodosViewWrite(includeTodoTags: true);
      attachedDatabase.notifyCapturesViewWrite();
    });
  }

  /// Move every reference to [from] onto [to], as its own capturing scope.
  ///
  /// The repair half of both `DomainReconciler` passes: the fold calls the private
  /// form inside its own scope, and the rehome pass — which repoints a junction
  /// whose `tag_id` has no row in `tags` at all — calls this one.
  Future<void> repointTagReferences({
    required String from,
    required String to,
  }) =>
      attachedDatabase.capturing(() async {
        await _repointTagReferences(from: from, to: to);
        attachedDatabase.notifyTodosViewWrite(includeTodoTags: true);
        attachedDatabase.notifyCapturesViewWrite();
      });

  /// Repoint **both** junction tables that reference `tags.id`.
  ///
  /// `todo_tags` and `capture_tags` — both, because FK enforcement is off (#637)
  /// so an orphaned junction row is not an error but a silently invisible Tag
  /// assignment or tag hint. Each junction's identity is its pair, so the row
  /// moves by inserting the derived id for `(parent, to)` and deleting the old
  /// one; a `(parent, to)` row that already existed collapses under the primary
  /// key via `INSERT OR REPLACE`. `[TagDao.merge]` still repoints only
  /// `todo_tags`; switching it onto this helper is #645.
  Future<void> _repointTagReferences({
    required String from,
    required String to,
  }) async {
    final todoJunctions =
        await (select(todoTags)..where((tt) => tt.tagId.equals(from))).get();
    for (final row in todoJunctions) {
      final movedId = todoTagIdFor(row.todoId, to);
      await into(todoTags).insert(
        TodoTagsCompanion(
          id: Value(movedId),
          todoId: Value(row.todoId),
          tagId: Value(to),
          userId: Value(row.userId),
        ),
        mode: InsertMode.insertOrReplace,
      );
      _captureTodoTag(row.todoId, to, row.userId);
      if (row.id != movedId) {
        await (delete(todoTags)..where((tt) => tt.id.equals(row.id))).go();
      }
      _tombstoneTodoTag(row.todoId, from);
    }

    final captureJunctions =
        await (select(captureTags)..where((ct) => ct.tagId.equals(from))).get();
    for (final row in captureJunctions) {
      final movedId = captureTagIdFor(row.captureId, to);
      await into(captureTags).insert(
        CaptureTagsCompanion(
          id: Value(movedId),
          captureId: Value(row.captureId),
          tagId: Value(to),
          userId: Value(row.userId),
        ),
        mode: InsertMode.insertOrReplace,
      );
      _captureCaptureTag(row.captureId, to, row.userId);
      if (row.id != movedId) {
        await (delete(captureTags)..where((ct) => ct.id.equals(row.id))).go();
      }
      _tombstoneCaptureTag(row.captureId, from);
    }
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
