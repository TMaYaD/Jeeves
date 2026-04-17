import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import 'auth_provider.dart';
import 'database_provider.dart';

export '../database/gtd_database.dart' show Todo;

/// Stream of next-action todos, excluding blocked tasks.
final nextActionsProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final userId = ref.watch(currentUserIdProvider);
  return db.todoDao.watchNextActions(userId);
});

/// Stream of waiting-for todos.
final waitingForProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final userId = ref.watch(currentUserIdProvider);
  return db.todoDao.watchWaitingFor(userId);
});

/// Stream of someday/maybe todos.
final somedayMaybeProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final userId = ref.watch(currentUserIdProvider);
  return db.todoDao.watchSomedayMaybe(userId);
});

/// Stream of blocked todos.
final blockedTasksProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final userId = ref.watch(currentUserIdProvider);
  return db.todoDao.watchByState(userId, 'blocked');
});

/// Stream of scheduled todos (all, for the Scheduled list screen).
final scheduledProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final userId = ref.watch(currentUserIdProvider);
  return db.todoDao.watchByState(userId, 'scheduled');
});
