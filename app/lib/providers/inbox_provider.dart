import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../models/todo.dart' hide Todo;
import 'auth_provider.dart';
import 'database_provider.dart';
import 'tag_filter_provider.dart';

export 'user_constants.dart' show kLocalUserId;

/// Stream of all inbox todos, newest first.
///
/// Automatically filtered by the active context tag set from
/// [tagFilterProvider] (AND semantics when multiple tags are selected).
final inboxItemsProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final userId = ref.watch(currentUserIdProvider);
  final tagIds = ref.watch(tagFilterProvider);
  return db.inboxDao.watchInbox(userId, tagIds: tagIds);
});

/// Notifier exposing inbox mutation operations.
final inboxNotifierProvider = Provider<InboxNotifier>((ref) {
  return InboxNotifier(ref);
});

class InboxNotifier {
  InboxNotifier(this._ref);

  final Ref _ref;

  Future<void> addTodo(String title, {String? notes}) async {
    final normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty) {
      throw ArgumentError.value(title, 'title', 'Title cannot be empty');
    }
    final db = _ref.read(databaseProvider);
    final now = DateTime.now();
    final userId = _ref.read(currentUserIdProvider);
    await db.inboxDao.insertTodo(TodosCompanion(
      title: Value(normalizedTitle),
      notes: Value(notes),
      state: Value(GtdState.inbox.value),
      captureSource: const Value('manual'),
      userId: Value(userId),
      createdAt: Value(now),
      updatedAt: Value(now),
    ));
  }
}
