import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../database/gtd_database.dart';
import '../models/todo.dart' hide Todo;
import 'database_provider.dart';

/// Placeholder user id until authentication is wired up.
const _localUserId = 'local';

/// Stream of all inbox todos, newest first.
final inboxItemsProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.inboxDao.watchInbox(_localUserId);
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
    final id = const Uuid().v4();
    final now = DateTime.now();
    await db.inboxDao.insertTodo(TodosCompanion(
      id: Value(id),
      title: Value(normalizedTitle),
      notes: Value(notes),
      state: Value(GtdState.inbox.value),
      captureSource: const Value('manual'),
      userId: const Value(_localUserId),
      createdAt: Value(now),
      updatedAt: Value(now),
    ));
  }
}
