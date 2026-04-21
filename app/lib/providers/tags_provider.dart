import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../database/daos/tag_dao.dart' show TagWithCount;
import '../database/gtd_database.dart';
import '../utils/tag_colors.dart';
import 'auth_provider.dart';
import 'database_provider.dart';

export '../database/daos/tag_dao.dart' show TagWithCount;

/// Runs once at startup (per user session) to backfill null colors on tags
/// that were created before the color field was populated.
///
/// Watch this provider high in the widget tree (e.g. AppShell) so the
/// backfill fires before tags are rendered.  Errors are swallowed — a missed
/// backfill is cosmetic (colors fall back to the derived palette at render
/// time via [resolvedTagColor]).
final tagColorBackfillProvider = FutureProvider<void>((ref) async {
  final db = ref.watch(databaseProvider);
  final userId = ref.watch(currentUserIdProvider);
  await db.tagDao.backfillMissingColors(userId);
});

/// Stream of all project tags for the current user.
final projectTagsProvider = StreamProvider<List<Tag>>((ref) {
  final db = ref.watch(databaseProvider);
  final userId = ref.watch(currentUserIdProvider);
  return db.tagDao.watchByType(userId, 'project');
});

/// Stream of all context tags for the current user.
final contextTagsProvider = StreamProvider<List<Tag>>((ref) {
  final db = ref.watch(databaseProvider);
  final userId = ref.watch(currentUserIdProvider);
  return db.tagDao.watchByType(userId, 'context');
});

/// Stream of context tags paired with their active-task counts.
final contextTagsWithCountProvider = StreamProvider<List<TagWithCount>>((ref) {
  final db = ref.watch(databaseProvider);
  final userId = ref.watch(currentUserIdProvider);
  return db.tagDao.watchTagsWithActiveCount(userId, 'context');
});

/// Exposes tag mutation operations.
final tagNotifierProvider = Provider<TagNotifier>((ref) => TagNotifier(ref));

class TagNotifier {
  TagNotifier(this._ref);

  final Ref _ref;

  Future<Tag> createTag(String name, String type) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > 100) {
      throw ArgumentError.value(
        name,
        'name',
        'Tag name must be between 1 and 100 characters.',
      );
    }

    final db = _ref.read(databaseProvider);
    final userId = _ref.read(currentUserIdProvider);
    final id = const Uuid().v4();
    final colorHex = tagColorToHex(tagColorForName(trimmed));
    final companion = TagsCompanion(
      id: Value(id),
      name: Value(trimmed),
      type: Value(type),
      color: Value(colorHex),
      userId: Value(userId),
    );
    await db.tagDao.upsertTag(companion);
    return Tag(id: id, name: trimmed, type: type, color: colorHex, userId: userId);
  }

  /// Rename an existing tag.
  Future<void> rename(String tagId, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed.length > 100) {
      throw ArgumentError.value(
        newName,
        'newName',
        'Tag name must be between 1 and 100 characters.',
      );
    }
    final db = _ref.read(databaseProvider);
    await db.tagDao.rename(tagId, trimmed);
  }

  /// Update the colour of a tag. Pass null to clear it.
  Future<void> updateColor(String tagId, String? color) {
    final db = _ref.read(databaseProvider);
    return db.tagDao.updateColor(tagId, color);
  }

  /// Merge [sourceTagId] into [targetTagId], reassigning all associations.
  Future<void> merge(String sourceTagId, String targetTagId) {
    final db = _ref.read(databaseProvider);
    return db.tagDao.merge(sourceTagId, targetTagId);
  }
}
