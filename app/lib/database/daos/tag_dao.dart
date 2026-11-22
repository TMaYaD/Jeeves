/// DAO for typed tags (context / project / area / label) and their todo associations.
library;

import 'package:drift/drift.dart';
import '../../utils/uuid.dart';

import '../../sync/collection_codecs.dart';
// The junction family derives its row ids here, so that a plugin which has to
// name a link — the vault, when a person types a label into a page — reaches
// the same derivation without the DAO layer. Re-exported so the callers that
// already read it from this file keep reading it from here.
import '../../sync/ids.dart' show captureTagIdFor, todoTagIdFor;
import '../../utils/tag_colors.dart';
import '../gtd_database.dart';
import 'focus_session_dao.dart' show FocusSessionDao;
// `habit_tags` is the third junction that references `tags.id`: it holds a
// Habit's Area and Labels. Its derived id lives with the Habit writes, in
// `habit_dao.dart`.
import 'habit_dao.dart' show habitTagIdFor;

export '../../sync/ids.dart' show todoTagIdFor;

part 'tag_dao.g.dart';

/// A [Tag] together with the count of active (not-done) tasks.
class TagWithCount {
  const TagWithCount({required this.tag, required this.count});

  final Tag tag;

  /// Number of active (not done) todos assigned this tag.
  final int count;
}

@DriftAccessor(tables: [Tags, TodoTags, Todos, CaptureTags, HabitTags])
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

  /// The context tags of the open session's Plan Outcomes, keyed by Outcome id,
  /// live (issue #407). Only tags of type `context` are returned, in name order;
  /// an Outcome with none is absent. Reads the same open session as
  /// [FocusSessionDao]'s Plan queries.
  Stream<Map<String, List<({String id, String name})>>>
      watchContextTagsForActiveSessionPlan() {
    return customSelect(
      'SELECT fst.task_id AS task_id, tags.id AS tag_id, tags.name AS tag_name '
      'FROM focus_session_tasks fst '
      'JOIN todo_tags tt ON tt.todo_id = fst.task_id '
      'JOIN tags ON tags.id = tt.tag_id AND tags.type = \'context\' '
      'WHERE fst.focus_session_id = (SELECT id FROM focus_sessions '
      'WHERE ended_at IS NULL '
      '${FocusSessionDao.openSessionWinnerFirstSql} LIMIT 1) '
      'ORDER BY tags.name, tags.id',
      variables: [],
      readsFrom: {attachedDatabase.focusSessionTasks, attachedDatabase.focusSessions, todoTags, tags},
    ).watch().map((rows) {
      final byTask = <String, List<({String id, String name})>>{};
      for (final row in rows) {
        (byTask[row.read<String>('task_id')] ??= []).add((
          id: row.read<String>('tag_id'),
          name: row.read<String>('tag_name'),
        ));
      }
      return byTask;
    });
  }

  /// Stream of tags of [type] paired with their active-task count.
  ///
  /// "Active" means done_at IS NULL (Inbox Captures are not todos).  Tags
  /// with zero active tasks return count = 0 and are still included so the
  /// cloud can show them as demoted/faded rather than vanishing mid-session.
  Stream<List<TagWithCount>> watchTagsWithActiveCount(String type) {
    return customSelect(
      'SELECT tags.id, tags.name, tags.color, tags.type, tags.user_id, '
      'COUNT(t.id) AS active_count '
      'FROM tags '
      'LEFT JOIN todo_tags tt ON tt.tag_id = tags.id '
      'LEFT JOIN todos t ON t.id = tt.todo_id AND t.done_at IS NULL '
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

  /// Removes the Outcome↔tag link and authors the tombstone a peer needs to
  /// drop it too. The Tag row stays. Runs in the caller's [capturing] scope.
  ///
  /// A link this device never held describes no effect, so the tombstone is
  /// gated on the delete having removed a row: a repeated or stale removal
  /// must not tombstone a pair a peer may have just assigned. Every other
  /// removal path in this DAO — [removeProjectFromTodo], [removeTagFromOutcomes]
  /// and the bulk Person set in `TodoDao.setPersonTagsForTodo` — tombstones
  /// only the links it found.
  Future<void> unassignTag(String todoId, String tagId) async {
    final removed = await (delete(todoTags)
          ..where((jt) => jt.todoId.equals(todoId) & jt.tagId.equals(tagId)))
        .go();
    if (removed > 0) _tombstoneTodoTag(todoId, tagId);
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

  /// Rename a tag like [rename], but never merge: when another tag of the same
  /// type already owns [newName], nothing is written and that tag is returned
  /// so the caller can ask the user before merging. Returns null when the
  /// rename was written (or was a no-op for an unknown tag or unchanged name).
  ///
  /// The collision check and the write share one transaction, so a namesake
  /// that arrives after the caller last looked cannot be merged silently.
  Future<Tag?> renameUnlessTaken(String tagId, String newName) {
    final trimmed = newName.trim();
    return attachedDatabase.capturing(() async {
      final current = await (select(tags)..where((t) => t.id.equals(tagId)))
          .getSingleOrNull();
      if (current == null || current.name == trimmed) return null;

      final conflict = await (select(tags)
            ..where((t) =>
                t.name.equals(trimmed) &
                t.type.equals(current.type) &
                t.id.equals(tagId).not())
            ..orderBy([(t) => OrderingTerm.asc(t.id)])
            ..limit(1))
          .getSingleOrNull();
      if (conflict != null) return conflict;

      await upsertTag(TagsCompanion(id: Value(tagId), name: Value(trimmed)));
      return null;
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
  /// Repoints every `todo_tags` row, every `capture_tags` row **and** every
  /// `habit_tags` row that references [sourceTagId] to [targetTagId] (an item
  /// holding both ends up with exactly one link to the target), then deletes
  /// the source tag. Colour and name of the target are kept.
  ///
  /// Throws [ArgumentError] if [sourceTagId] equals [targetTagId] — a
  /// self-merge would silently delete the tag and strip every association — or
  /// if either tag is missing or the two differ in `type`: a project folded
  /// into a person is never what the user meant.
  Future<void> merge(String sourceTagId, String targetTagId) {
    if (sourceTagId == targetTagId) {
      throw ArgumentError.value(
        targetTagId,
        'targetTagId',
        'Source and target tags must differ',
      );
    }
    return attachedDatabase.capturing(() async {
      final source = await (select(tags)..where((t) => t.id.equals(sourceTagId)))
          .getSingleOrNull();
      final target = await (select(tags)..where((t) => t.id.equals(targetTagId)))
          .getSingleOrNull();
      if (source == null || target == null) {
        throw ArgumentError.value(
          source == null ? sourceTagId : targetTagId,
          source == null ? 'sourceTagId' : 'targetTagId',
          'Tag does not exist',
        );
      }
      if (source.type != target.type) {
        throw ArgumentError.value(
          targetTagId,
          'targetTagId',
          'Source and target tags must have the same type',
        );
      }
      await _repointTagReferences(from: sourceTagId, to: targetTagId);
      await (delete(tags)..where((t) => t.id.equals(sourceTagId))).go();
      attachedDatabase.opCapture
          .tombstone(collection: tagsCollection, entityId: sourceTagId);
      attachedDatabase.notifyTodosViewWrite(includeTodoTags: true);
      attachedDatabase.notifyCapturesViewWrite();
    });
  }

  /// Delete [tagId] outright — the *user's* deliberate removal of a Tag,
  /// Project or Person from every Outcome and Capture hint that carried it.
  /// The Outcomes and Captures themselves stay.
  ///
  /// The op log has no foreign-key cascade, so every junction row the tag held
  /// (`todo_tags` and `capture_tags`) is tombstoned explicitly alongside the
  /// tag. Does not stamp `last_clarified_at`: removing an entry from a
  /// management list is not thinking about each Outcome. Returns without
  /// writing when [tagId] is unknown.
  ///
  /// A Habit's `habit_tags` row goes too, and **without a tombstone**: the
  /// habit tables are local until Habits sync, so there is no op to author and
  /// no peer to tell. The row would otherwise sit on as an orphan pointing at
  /// a tag that is gone — invisible to the read, but still a row.
  Future<void> deleteTag(String tagId) {
    return attachedDatabase.capturing(() async {
      final existing = await (select(tags)..where((t) => t.id.equals(tagId)))
          .getSingleOrNull();
      if (existing == null) return;
      final todoJunctions =
          await (select(todoTags)..where((tt) => tt.tagId.equals(tagId))).get();
      final captureJunctions = await (select(captureTags)
            ..where((ct) => ct.tagId.equals(tagId)))
          .get();
      await (delete(todoTags)..where((tt) => tt.tagId.equals(tagId))).go();
      await (delete(captureTags)..where((ct) => ct.tagId.equals(tagId))).go();
      await (delete(habitTags)..where((ht) => ht.tagId.equals(tagId))).go();
      for (final row in todoJunctions) {
        _tombstoneTodoTag(row.todoId, tagId);
      }
      for (final row in captureJunctions) {
        _tombstoneCaptureTag(row.captureId, tagId);
      }
      await (delete(tags)..where((t) => t.id.equals(tagId))).go();
      attachedDatabase.opCapture
          .tombstone(collection: tagsCollection, entityId: tagId);
      attachedDatabase.notifyTodosViewWrite(includeTodoTags: true);
      attachedDatabase.notifyCapturesViewWrite();
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

  /// Retype every Tag still carrying the retired `'label'` type to `'context'`.
  ///
  /// Labels used to be stored under two `tags.type` values: `'context'` — the
  /// `@` rows every released build already shows as its Labels — and `'label'`,
  /// what the sync cutover minted surplus Areas as, which no surface showed.
  /// One value backs Labels now, and this is what folds the other into it.
  ///
  /// **The tag id does not change**, so every link to the Tag stays exactly
  /// where it was: an Outcome's assignment (`todo_tags`) and a Capture's tag
  /// hint (`capture_tags`) both reference the tag by id. Only the `type` field
  /// is written.
  ///
  /// **It travels as an op**, so a peer's copy is retyped too: the write goes
  /// through [upsertTag], which describes the field change to the capture seam.
  /// That is what lets two devices converge on one value — and it needs no wire
  /// step, because a peer on an older build reads `'context'` as its Label
  /// surface already (docs/SYNC.md).
  ///
  /// Idempotent: with no retired row it writes nothing and authors no op.
  /// Returns the number of rows retyped.
  Future<int> retypeRetiredLabelTags() {
    return attachedDatabase.capturing(() async {
      final retired = await (select(tags)
            ..where((t) => t.type.equals(retiredLabelTagType))
            ..orderBy([(t) => OrderingTerm.asc(t.id)]))
          .get();
      if (retired.isEmpty) return 0;
      for (final tag in retired) {
        await upsertTag(TagsCompanion(
          id: Value(tag.id),
          type: const Value(labelTagType),
        ));
      }
      attachedDatabase.notifyTagsViewWrite();
      return retired.length;
    });
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
  /// With [userId] set, only that account's rows are grouped, so a same-name
  /// row left on the device by another account is never folded into it. The
  /// reconciler and the startup fold pass none: they fold the whole store.
  ///
  /// Idempotent: with no duplicate group it authors nothing and writes nothing.
  Future<void> foldDuplicateTags({String? userId}) {
    return attachedDatabase.capturing(() async {
      final groups = await customSelect(
        'SELECT name, type, MIN(id) AS keep_id FROM tags '
        '${userId == null ? '' : 'WHERE user_id = ? '}'
        'GROUP BY name, type HAVING COUNT(*) > 1',
        variables: [if (userId != null) Variable<String>(userId)],
        readsFrom: {tags},
      ).get();
      if (groups.isEmpty) return;

      for (final group in groups) {
        final keepId = group.read<String>('keep_id');
        final losers = await (select(tags)
              ..where((t) =>
                  t.name.equals(group.read<String>('name')) &
                  t.type.equals(group.read<String>('type')) &
                  (userId == null ? const Constant(true) : t.userId.equals(userId)) &
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

  /// Outcomes holding more than one link to a live `project`-typed Tag, as
  /// `{todo id: [project tag ids]}`. A link whose Tag has no row is not counted;
  /// the rehome pass owns it.
  Future<Map<String, List<String>>> outcomesWithMultipleProjects() async {
    final rows = await customSelect(
      'SELECT tt.todo_id AS todo_id, tt.tag_id AS tag_id '
      'FROM todo_tags tt JOIN tags t ON t.id = tt.tag_id '
      "WHERE t.type = 'project' AND tt.todo_id IN ("
      '  SELECT tt2.todo_id FROM todo_tags tt2 '
      '  JOIN tags t2 ON t2.id = tt2.tag_id '
      "  WHERE t2.type = 'project' "
      '  GROUP BY tt2.todo_id HAVING COUNT(*) > 1) '
      'ORDER BY tt.todo_id, tt.tag_id',
      readsFrom: {todoTags, tags},
    ).get();
    final byOutcome = <String, List<String>>{};
    for (final row in rows) {
      byOutcome
          .putIfAbsent(row.read<String>('todo_id'), () => <String>[])
          .add(row.read<String>('tag_id'));
    }
    return byOutcome;
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
        // The destination was chosen before this scope began. If it has gone
        // since (merged away or deleted), moving references onto it would
        // strand them again, so they stay where they are.
        final destination = await (select(tags)..where((t) => t.id.equals(to)))
            .getSingleOrNull();
        if (destination == null) return;
        await _repointTagReferences(from: from, to: to);
        attachedDatabase.notifyTodosViewWrite(includeTodoTags: true);
        attachedDatabase.notifyCapturesViewWrite();
      });

  /// Repoint **every** junction table that references `tags.id`.
  ///
  /// `todo_tags`, `capture_tags` and `habit_tags` — all three, because FK
  /// enforcement is off (#637) so an orphaned junction row is not an error but
  /// a silently invisible Tag assignment, tag hint or Habit Label. Each
  /// junction's identity is its pair, so the row moves by inserting the
  /// derived id for `(parent, to)` and deleting the old one; a `(parent, to)`
  /// row that already existed collapses under the primary key via
  /// `INSERT OR REPLACE`.
  ///
  /// The `habit_tags` rows move **without an op**: the habit tables are local
  /// until Habits sync, so there is nothing to author and no peer to tell.
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

    // The Habit's Area and Labels. No op is authored: the habit tables are
    // local until Habits sync.
    final habitJunctions =
        await (select(habitTags)..where((ht) => ht.tagId.equals(from))).get();
    for (final row in habitJunctions) {
      final movedId = habitTagIdFor(row.habitId, to);
      await into(habitTags).insert(
        HabitTagsCompanion.insert(
          id: movedId,
          habitId: row.habitId,
          tagId: to,
          userId: row.userId,
        ),
        mode: InsertMode.insertOrReplace,
      );
      if (row.id != movedId) {
        await (delete(habitTags)..where((ht) => ht.id.equals(row.id))).go();
      }
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

  /// Removes the Outcome's Project link — the link, not the Project Tag.
  ///
  /// The removal-side counterpart of [enforceSingleProject]: an Outcome holds
  /// at most one Project, so clearing it drops the junction row and authors
  /// the tombstone a peer needs to drop it too. Without that tombstone the
  /// removal stays on this device, and the next pull restores the Project the
  /// user just cleared.
  ///
  /// A junction that was not there to begin with describes no effect, so
  /// clearing an Outcome that holds no Project authors nothing.
  Future<void> removeProjectFromTodo(String todoId) async {
    await attachedDatabase.capturing(() async {
      final projectTagIds =
          await (select(tags)..where((t) => t.type.equals('project')))
              .map((t) => t.id)
              .get();
      if (projectTagIds.isEmpty) return;

      final held = await (select(todoTags)
            ..where(
              (jt) => jt.todoId.equals(todoId) & jt.tagId.isIn(projectTagIds),
            ))
          .get();
      if (held.isEmpty) return;

      await (delete(todoTags)
            ..where(
              (jt) => jt.todoId.equals(todoId) & jt.tagId.isIn(projectTagIds),
            ))
          .go();
      for (final row in held) {
        _tombstoneTodoTag(todoId, row.tagId);
      }
    });
  }

  // ── Bulk Organising (list multi-select) ────────────────────────────────────
  //
  // Each method is ONE `capturing` scope = one transaction: a throw rolls the
  // whole batch back and authors no ops. An id with no `todos` row is skipped
  // inside that transaction (#444 / #446 / #447), so a row deleted underneath
  // an open sheet writes nothing. None of them touches `todos`: Organising
  // never stamps `last_clarified_at`.

  Future<Set<String>> _presentOutcomeIds(Set<String> outcomeIds) async {
    if (outcomeIds.isEmpty) return <String>{};
    final rows = await (select(todos)..where((t) => t.id.isIn(outcomeIds)))
        .map((t) => t.id)
        .get();
    return rows.toSet();
  }

  Future<Tag?> _tagOfTypeOrNull(String tagId) =>
      (select(tags)..where((t) => t.id.equals(tagId))).getSingleOrNull();

  /// Adds the [tagId] Tag (a `context`-typed tag) to every present Outcome in
  /// [outcomeIds]. Returns the ids written; empty if the Tag is gone.
  ///
  /// Throws [ArgumentError] for a `person` or `project` tag: a person tag is a
  /// PersonBlocker (a Clarification, owned by the status action) and a project
  /// tag must go through [setProjectForOutcomes]'s single-Project rule.
  Future<Set<String>> assignTagToOutcomes(
      Set<String> outcomeIds, String tagId, String userId) async {
    final written = <String>{};
    await attachedDatabase.capturing(() async {
      final tag = await _tagOfTypeOrNull(tagId);
      if (tag == null) return;
      _requireBulkTagType(tag);
      for (final id in await _presentOutcomeIds(outcomeIds)) {
        await assignTag(id, tagId, userId);
        written.add(id);
      }
    });
    if (written.isNotEmpty) {
      attachedDatabase.notifyTodosViewWrite(includeTodoTags: true);
    }
    return written;
  }

  /// Removes the [tagId] Tag from every Outcome in [outcomeIds] that holds it,
  /// authoring a tombstone per removed junction (none for an Outcome that never
  /// held it). Returns the ids it was removed from. Same type guard as
  /// [assignTagToOutcomes].
  Future<Set<String>> removeTagFromOutcomes(
      Set<String> outcomeIds, String tagId) async {
    final removed = <String>{};
    await attachedDatabase.capturing(() async {
      final tag = await _tagOfTypeOrNull(tagId);
      if (tag != null) _requireBulkTagType(tag);
      final present = await _presentOutcomeIds(outcomeIds);
      if (present.isEmpty) return;
      final held = await (select(todoTags)
            ..where((tt) => tt.tagId.equals(tagId) & tt.todoId.isIn(present)))
          .get();
      for (final row in held) {
        await (delete(todoTags)..where((tt) => tt.id.equals(row.id))).go();
        _tombstoneTodoTag(row.todoId, tagId);
        removed.add(row.todoId);
      }
    });
    if (removed.isNotEmpty) {
      attachedDatabase.notifyTodosViewWrite(includeTodoTags: true);
    }
    return removed;
  }

  /// Makes [projectTagId] the one Project of every present Outcome in
  /// [outcomeIds] (the body of [enforceSingleProject], per Outcome). Returns the
  /// ids written; empty if the Project tag is gone.
  Future<Set<String>> setProjectForOutcomes(
      Set<String> outcomeIds, String projectTagId, String userId) async {
    final written = <String>{};
    await attachedDatabase.capturing(() async {
      final tag = await _tagOfTypeOrNull(projectTagId);
      if (tag == null) return;
      if (tag.type != 'project') {
        throw ArgumentError.value(
            projectTagId, 'projectTagId', 'is not a project tag');
      }
      for (final id in await _presentOutcomeIds(outcomeIds)) {
        await enforceSingleProject(id, userId, projectTagId);
        written.add(id);
      }
    });
    if (written.isNotEmpty) {
      attachedDatabase.notifyTodosViewWrite(includeTodoTags: true);
    }
    return written;
  }

  static void _requireBulkTagType(Tag tag) {
    if (tag.type == 'person' || tag.type == 'project') {
      throw ArgumentError.value(tag.id, 'tagId',
          'bulk tag edits do not accept a ${tag.type} tag');
    }
  }
}
