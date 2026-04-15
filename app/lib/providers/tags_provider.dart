import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../database/gtd_database.dart';
import 'database_provider.dart';
import 'inbox_provider.dart' show kLocalUserId;

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
    final db = _ref.read(databaseProvider);
    final id = const Uuid().v4();
    final companion = TagsCompanion(
      id: Value(id),
      name: Value(name.trim()),
      type: Value(type),
      userId: const Value(kLocalUserId),
    );
    await db.tagDao.upsertTag(companion);
    return Tag(id: id, name: name.trim(), type: type, userId: kLocalUserId);
  }
}
