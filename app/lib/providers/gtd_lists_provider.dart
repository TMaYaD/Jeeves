import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import 'auth_provider.dart';
import 'database_provider.dart';
import 'tag_filter_provider.dart';

export '../database/gtd_database.dart' show Todo;

/// Stream of next-action todos.
///
/// Automatically filtered by the active context tag set from
/// [tagFilterProvider] (AND semantics when multiple tags are selected).
final nextActionsProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final userId = ref.watch(currentUserIdProvider);
  final tagIds = ref.watch(tagFilterProvider);
  return db.todoDao.watchNextActions(userId, tagIds: tagIds);
});

/// Stream of waiting-for todos.
final waitingForProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final userId = ref.watch(currentUserIdProvider);
  final tagIds = ref.watch(tagFilterProvider);
  return db.todoDao.watchWaitingFor(userId, tagIds: tagIds);
});

/// Stream of someday/maybe todos.
final somedayMaybeProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final userId = ref.watch(currentUserIdProvider);
  final tagIds = ref.watch(tagFilterProvider);
  return db.todoDao.watchSomedayMaybe(userId, tagIds: tagIds);
});
