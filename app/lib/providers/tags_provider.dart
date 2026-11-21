import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/tag_dao.dart' show TagWithCount;
import '../database/gtd_database.dart';
import 'tag_filter_provider.dart';
import 'auth_provider.dart';
import 'database_provider.dart';

export '../database/daos/tag_dao.dart' show TagWithCount;

/// Stream of all project tags.
final projectTagsProvider = StreamProvider<List<Tag>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.tagDao.watchByType('project');
});

/// Stream of all context tags.
final contextTagsProvider = StreamProvider<List<Tag>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.tagDao.watchByType('context');
});

/// Stream of the tags of one [type] (`area`, `context`, `project`, …).
///
/// The single-choice tag picker reads the rows of the type it was given.
final tagsByTypeProvider =
    StreamProvider.family<List<Tag>, String>((ref, type) {
  final db = ref.watch(databaseProvider);
  return db.tagDao.watchByType(type);
});

/// Stream of all person tags.
final personTagsProvider = StreamProvider<List<Tag>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.tagDao.watchPersonTags();
});

/// Stream of context tags paired with their active-task counts.
final contextTagsWithCountProvider = StreamProvider<List<TagWithCount>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.tagDao.watchTagsWithActiveCount('context');
});

/// Tags of one [type] (`context`, `project` or `person`) with their
/// active-Outcome counts — the rows of the management list screen.
final tagsWithCountByTypeProvider =
    StreamProvider.family<List<TagWithCount>, String>((ref, type) {
  final db = ref.watch(databaseProvider);
  return db.tagDao.watchTagsWithActiveCount(type);
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
        'Name must be between 1 and 100 characters.',
      );
    }

    final db = _ref.read(databaseProvider);
    final userId = _ref.read(currentUserIdProvider);
    final id = await db.tagDao.findOrCreateTag(trimmed, type, userId);
    // Read back so callers receive the canonical row (color, user_id) when
    // findOrCreateTag reused a pre-existing tag instead of minting a new one.
    return (db.select(db.tags)..where((t) => t.id.equals(id))).getSingle();
  }

  /// Rename an existing tag.
  Future<void> rename(String tagId, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed.length > 100) {
      throw ArgumentError.value(
        newName,
        'newName',
        'Name must be between 1 and 100 characters.',
      );
    }
    final db = _ref.read(databaseProvider);
    await db.tagDao.rename(tagId, trimmed);
  }

  /// Rename without ever merging: returns the same-kind entry already holding
  /// [newName] (nothing written) so the caller can confirm a [merge], or null
  /// when the rename was written. The check and write are one transaction.
  Future<Tag?> renameUnlessTaken(String tagId, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed.length > 100) {
      throw ArgumentError.value(
        newName,
        'newName',
        'Name must be between 1 and 100 characters.',
      );
    }
    final db = _ref.read(databaseProvider);
    return db.tagDao.renameUnlessTaken(tagId, trimmed);
  }

  /// Update the colour of a tag. Pass null to clear it.
  Future<void> updateColor(String tagId, String? color) {
    final db = _ref.read(databaseProvider);
    return db.tagDao.updateColor(tagId, color);
  }

  /// Merge [sourceTagId] into [targetTagId], reassigning all associations.
  ///
  /// If the merged-away tag was in the active tag filter it is swapped for the
  /// target, so list providers keep returning the user's intended results.
  Future<void> merge(String sourceTagId, String targetTagId) async {
    final db = _ref.read(databaseProvider);
    await db.tagDao.merge(sourceTagId, targetTagId);
    final filter = _ref.read(tagFilterProvider);
    if (filter.contains(sourceTagId)) {
      final notifier = _ref.read(tagFilterProvider.notifier);
      notifier.toggle(sourceTagId);
      if (!filter.contains(targetTagId)) notifier.toggle(targetTagId);
    }
  }

  /// Delete [tagId] from every Outcome and Capture that carried it; the
  /// Outcomes and Captures stay. Drops it from the active tag filter.
  Future<void> delete(String tagId) async {
    final db = _ref.read(databaseProvider);
    await db.tagDao.deleteTag(tagId);
    if (_ref.read(tagFilterProvider).contains(tagId)) {
      _ref.read(tagFilterProvider.notifier).toggle(tagId);
    }
  }
}

/// Folds the retired `'label'` Tag type into the one value Labels have, once per
/// launch. Eagerly watched from `main.dart`.
///
/// Reconciliation retypes the rows a peer sends, but a row this device holds
/// from an earlier sync cutover or an import never passes through a reconcile
/// tail, so it is retyped here and then folded into any same-name Label. Both
/// steps are idempotent and cheap — with nothing retired they write nothing and
/// author no op — so no completion marker is kept. Ordered after
/// [domainStoreRebuildProvider] so the post-upgrade re-projection cannot bring a
/// retired row back. A failure rethrows into the provider's error state.
final FutureProvider<int> labelTagTypeFoldProvider =
    FutureProvider<int>((ref) async {
  ref.keepAlive();
  await ref.read(domainStoreRebuildProvider.future);
  final db = ref.read(databaseProvider);
  try {
    final retyped = await db.tagDao.retypeRetiredLabelTags();
    if (retyped > 0) await db.tagDao.foldDuplicateTags();
    return retyped;
  } on Object catch (error) {
    debugPrint('label tag type fold: failed — $error');
    rethrow;
  }
});
