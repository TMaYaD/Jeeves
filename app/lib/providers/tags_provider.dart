import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../database/gtd_database.dart';
import 'database_provider.dart';
import 'user_constants.dart' show kLocalUserId;

/// Stream of all project tags for the local user.
final projectTagsProvider = StreamProvider<List<Tag>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.tagDao.watchByType(kLocalUserId, 'project');
});

/// Stream of all context tags for the local user.
final contextTagsProvider = StreamProvider<List<Tag>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.tagDao.watchByType(kLocalUserId, 'context');
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
    final id = const Uuid().v4();
    final companion = TagsCompanion(
      id: Value(id),
      name: Value(trimmed),
      type: Value(type),
      userId: const Value(kLocalUserId),
    );
    await db.tagDao.upsertTag(companion);
    return Tag(id: id, name: trimmed, type: type, userId: kLocalUserId);
  }
}
